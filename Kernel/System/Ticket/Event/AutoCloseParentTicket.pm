package Kernel::System::Ticket::Event::AutoCloseParentTicket;

use strict;
use warnings;

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

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $LogObject    = $Kernel::OM->Get('Kernel::System::Log');
    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');
    my $StateObject  = $Kernel::OM->Get('Kernel::System::State');
    my $LinkObject   = $Kernel::OM->Get('Kernel::System::LinkObject');

    return 1 if !$Param{Data}->{TicketID};
    
    my $TicketID = $Param{Data}->{TicketID};
    my $UserID   = $Param{UserID} || 1;
    
    return 1 if $Param{Event} ne 'TicketStateUpdate';
    
    $LogObject->Log( Priority => 'notice', Message => "AutoCloseParentTicket: Checking TicketID=$TicketID" );

    my $ParentCloseStateName = $ConfigObject->Get('AutoCloseParentTicket::ParentCloseState') || 'closed successful';
    my $ChildClosedStatesStr = $ConfigObject->Get('AutoCloseParentTicket::ChildClosedStates') || 'closed successful,closed unsuccessful';
    my @ChildClosedStateNames = split(/\s*,\s*/, $ChildClosedStatesStr);
    
    my %ChildClosedStateIDs;
    for my $StateName (@ChildClosedStateNames) {
        my $StateID = $StateObject->StateLookup( State => $StateName );
        $ChildClosedStateIDs{$StateID} = 1 if $StateID;
    }
    
    my $ParentCloseStateID = $StateObject->StateLookup( State => $ParentCloseStateName );
    if ( !$ParentCloseStateID ) {
        $LogObject->Log( Priority => 'error', Message => "AutoCloseParentTicket: Invalid parent close state: $ParentCloseStateName" );
        return 1;
    }
    
    my $LinkList = $LinkObject->LinkList(
        Object     => 'Ticket',
        Key        => $TicketID,
        State      => 'Valid',
        Type       => '',
        Direction  => 'Both',
        UserID     => $UserID,
    );
    
    my @ParentIDs;
    if ( $LinkList && ref $LinkList eq 'HASH' ) {
        for my $ObjectType ( keys %{$LinkList} ) {
            next if $ObjectType ne 'Ticket';
            for my $LinkType ( keys %{ $LinkList->{$ObjectType} } ) {
                for my $Direction ( keys %{ $LinkList->{$ObjectType}{$LinkType} } ) {
                    for my $LinkedID ( keys %{ $LinkList->{$ObjectType}{$LinkType}{$Direction} } ) {
                        push @ParentIDs, $LinkedID if $LinkedID =~ /^\d+$/;
                    }
                }
            }
        }
    }
    
    if ( scalar(@ParentIDs) == 0 ) {
        return 1;
    }
    
    my $ParentID = $ParentIDs[0];
    $LogObject->Log( Priority => 'notice', Message => "AutoCloseParentTicket: Parent ID = $ParentID" );
    
    # Obținem toate child-urile parent-ului
    my $ParentLinkList = $LinkObject->LinkList(
        Object     => 'Ticket',
        Key        => $ParentID,
        State      => 'Valid',
        Type       => '',
        Direction  => 'Both',
        UserID     => $UserID,
    );
    
    my @Children;
    if ( $ParentLinkList && ref $ParentLinkList eq 'HASH' ) {
        for my $ObjectType ( keys %{$ParentLinkList} ) {
            next if $ObjectType ne 'Ticket';
            for my $LinkType ( keys %{ $ParentLinkList->{$ObjectType} } ) {
                for my $Direction ( keys %{ $ParentLinkList->{$ObjectType}{$LinkType} } ) {
                    for my $LinkedID ( keys %{ $ParentLinkList->{$ObjectType}{$LinkType}{$Direction} } ) {
                        next if $LinkedID == $ParentID;
                        push @Children, $LinkedID if $LinkedID =~ /^\d+$/;
                    }
                }
            }
        }
    }
    
    my %UniqueChildren;
    $UniqueChildren{$_} = 1 for @Children;
    @Children = keys %UniqueChildren;
    
    return 1 if scalar(@Children) == 0;
    
    # Verificăm dacă TOATE child-urile sunt închise
    my $AllClosed = 1;
    my $ClosedCount = 0;
    
    for my $ChildID (@Children) {
        my %Child = $TicketObject->TicketGet( TicketID => $ChildID, UserID => $UserID );
        if ( $ChildClosedStateIDs{ $Child{StateID} } ) {
            $ClosedCount++;
        } else {
            $AllClosed = 0;
        }
    }
    
    $LogObject->Log( Priority => 'notice', Message => "AutoCloseParentTicket: Closed: $ClosedCount, Total: " . scalar(@Children) . ", AllClosed: $AllClosed" );
    
    if ( $AllClosed ) {
        # Închidem direct parent-ul (fără pending reminder)
        $LogObject->Log( Priority => 'notice', Message => "AutoCloseParentTicket: CLOSING parent $ParentID to state $ParentCloseStateName" );
        
        my $Success = $TicketObject->TicketStateSet(
            TicketID => $ParentID,
            StateID  => $ParentCloseStateID,
            UserID   => $UserID,
            Comment  => 'Automatically closed because all child tickets are completed.',
        );
        
        if ($Success) {
            $LogObject->Log( Priority => 'notice', Message => "AutoCloseParentTicket: SUCCESS - Parent $ParentID closed" );
        } else {
            $LogObject->Log( Priority => 'error', Message => "AutoCloseParentTicket: FAILED to close parent $ParentID" );
        }
    } else {
        $LogObject->Log( Priority => 'notice', Message => "AutoCloseParentTicket: Parent $ParentID remains open (waiting for " . (scalar(@Children) - $ClosedCount) . " more child(s))" );
    }
    
    return 1;
}

1;