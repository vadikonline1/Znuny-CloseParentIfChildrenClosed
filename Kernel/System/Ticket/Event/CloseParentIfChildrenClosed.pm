package Kernel::System::Ticket::Event::CloseParentIfChildrenClosed;

use strict;
use warnings;
use utf8;

use Kernel::System::VariableCheck qw(:all);

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::Log',
    'Kernel::System::Ticket',
    'Kernel::System::State',
    'Kernel::System::LinkObject',
);

sub new {
    my ( $Type, %Param ) = @_;
    return bless {}, $Type;
}

sub Run {
    my ( $Self, %Param ) = @_;
    
    # Verifică dacă modulul este activat din SysConfig
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $IsEnabled = $ConfigObject->Get('ParentAutoClose::Enabled') // 1;
    
    return if !$IsEnabled;
    
    # Verifică dacă avem TicketID valid
    return if !IsPositiveInteger( $Param{Data}->{TicketID} );
    
    my $TicketID = $Param{Data}->{TicketID};
    
    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');
    my $LinkObject   = $Kernel::OM->Get('Kernel::System::LinkObject');
    my $StateObject  = $Kernel::OM->Get('Kernel::System::State');
    my $LogObject    = $Kernel::OM->Get('Kernel::System::Log');
    
    # Configurații din SysConfig
    my $TargetState   = $ConfigObject->Get('ParentAutoClose::TargetState') || 'closed successful';
    my $LinkType      = $ConfigObject->Get('ParentAutoClose::LinkType') || 'ParentChild';
    my $OnlySuccessful = $ConfigObject->Get('ParentAutoClose::OnlySuccessful') || 0;
    my $AddNote        = $ConfigObject->Get('ParentAutoClose::AddNote') || 0;
    my $ExcludeQueues  = $ConfigObject->Get('ParentAutoClose::ExcludeQueues') || [];
    my $Logging        = $ConfigObject->Get('ParentAutoClose::Logging') || 0;
    
    # Ia ticketul curent
    my %Ticket = $TicketObject->TicketGet(
        TicketID => $TicketID,
        DynamicFields => 0,
    );
    
    return if !$Ticket{TicketID};
    
    # Verifică dacă ticketul este exclus pe bază de queue
    if ( IsArrayRefWithData($ExcludeQueues) ) {
        my %QueueData = $TicketObject->TicketQueueLookup( TicketID => $TicketID );
        if ( grep { $_ eq $QueueData{Name} } @{$ExcludeQueues} ) {
            $LogObject->Log( Priority => 'info', Message => "ParentAutoClose: Skipped ticket $TicketID (excluded queue)" ) if $Logging;
            return;
        }
    }
    
    # Verifică tipul de stare al ticketului curent
    my $StateType = $StateObject->StateGet(
        ID => $Ticket{StateID},
    )->{Type};
    
    # Doar dacă ticketul curent a fost închis
    return if $StateType ne 'closed';
    
    $LogObject->Log( Priority => 'debug', Message => "ParentAutoClose: Ticket $TicketID closed, checking for parent" ) if $Logging;
    
    # Găsește părintele (link direction: Source = child, Target = parent)
    my $Links = $LinkObject->LinkList(
        Object    => 'Ticket',
        Key       => $TicketID,
        State     => 'Valid',
        Type      => $LinkType,
        Direction => 'Source',  # child -> parent
    );
    
    return if !$Links->{Ticket};
    
    my $ClosedCount = 0;
    my $TotalChildren = 0;
    
    for my $ParentID ( keys %{ $Links->{Ticket}->{$LinkType}->{Source} || {} } ) {
        
        $LogObject->Log( Priority => 'debug', Message => "ParentAutoClose: Found parent $ParentID for child $TicketID" ) if $Logging;
        
        # Găsește toți copiii pentru acest părinte
        my $ChildLinks = $LinkObject->LinkList(
            Object    => 'Ticket',
            Key       => $ParentID,
            State     => 'Valid',
            Type      => $LinkType,
            Direction => 'Target',  # parent -> children
        );
        
        my $AllClosed = 1;
        my @OpenChildren;
        
        for my $ChildID ( keys %{ $ChildLinks->{Ticket}->{$LinkType}->{Target} || {} } ) {
            $TotalChildren++;
            
            my %ChildTicket = $TicketObject->TicketGet(
                TicketID => $ChildID,
                DynamicFields => 0,
            );
            
            my $ChildStateType = $StateObject->StateGet(
                ID => $ChildTicket{StateID},
            )->{Type};
            
            # Verifică dacă starea este closed (sau closed successful dacă e configurat)
            my $IsClosed = 0;
            
            if ($OnlySuccessful) {
                # Doar 'closed successful' contează
                my $StateName = $StateObject->StateLookup( StateID => $ChildTicket{StateID} );
                $IsClosed = ($StateName eq 'closed successful');
            }
            else {
                $IsClosed = ($ChildStateType eq 'closed');
            }
            
            if ($IsClosed) {
                $ClosedCount++;
            }
            else {
                $AllClosed = 0;
                push @OpenChildren, $ChildID;
            }
        }
        
        # Dacă toți copiii sunt închiși, închide părintele
        if ($AllClosed && $TotalChildren > 0) {
            $LogObject->Log( Priority => 'info', Message => "ParentAutoClose: Closing parent $ParentID (all $TotalChildren children closed)" ) if $Logging;
            
            # Închide părintele
            my $Success = $TicketObject->TicketStateSet(
                TicketID => $ParentID,
                State    => $TargetState,
                UserID   => 1,  # System user
            );
            
            if ($Success && $AddNote) {
                # Adaugă notă în ticketul părinte
                my $Note = $ConfigObject->Get('ParentAutoClose::NoteText') 
                    || "All child tickets have been closed. Parent ticket closed automatically.";
                
                $TicketObject->ArticleCreate(
                    TicketID       => $ParentID,
                    ArticleType    => 'note-internal',
                    SenderType     => 'system',
                    Subject        => 'Auto-closed: all children completed',
                    Body           => $Note,
                    UserID         => 1,
                    HistoryType    => 'AddNote',
                    HistoryComment => 'Auto-closed by ParentAutoClose plugin',
                );
            }
        }
        else {
            $LogObject->Log( Priority => 'debug', Message => "ParentAutoClose: Parent $ParentID not closed, still has " . scalar(@OpenChildren) . " open children" ) if $Logging;
        }
    }
    
    return 1;
}

1;
