# Kernel/System/Ticket/Event/CloseParentIfChildrenClosed.pm

package Kernel::System::Ticket::Event::CloseParentIfChildrenClosed;

use strict;
use warnings;
use Kernel::System::VariableCheck qw(:all);

sub new {
    my ( $Type, %Param ) = @_;
    return bless {}, $Type;
}

sub Run {
    my ( $Self, %Param ) = @_;

    return if !IsPositiveInteger( $Param{Data}->{TicketID} );

    my $TicketID = $Param{Data}->{TicketID};

    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');
    my $LinkObject   = $Kernel::OM->Get('Kernel::System::LinkObject');
    my $StateObject  = $Kernel::OM->Get('Kernel::System::State');
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    my $TargetState = $ConfigObject->Get('ParentAutoCloseState') || 'closed successful';
    my $LinkType    = $ConfigObject->Get('ParentAutoCloseLinkType') || 'ParentChild';

    my %Ticket = $TicketObject->TicketGet(
        TicketID => $TicketID,
    );

    return if !$Ticket{TicketID};

    my $StateType = $StateObject->StateGet(
        ID => $Ticket{StateID},
    )->{Type};

    return if $StateType ne 'closed';

    my $Links = $LinkObject->LinkList(
        Object    => 'Ticket',
        Key       => $TicketID,
        State     => 'Valid',
        Type      => $LinkType,
        Direction => 'Source',
    );

    return if !$Links->{Ticket};

    for my $ParentID ( keys %{ $Links->{Ticket}->{$LinkType}->{Source} || {} } ) {

        my $ChildLinks = $LinkObject->LinkList(
            Object    => 'Ticket',
            Key       => $ParentID,
            State     => 'Valid',
            Type      => $LinkType,
            Direction => 'Target',
        );

        my $AllClosed = 1;

        for my $ChildID ( keys %{ $ChildLinks->{Ticket}->{$LinkType}->{Target} || {} } ) {

            my %ChildTicket = $TicketObject->TicketGet(
                TicketID => $ChildID,
            );

            my $ChildStateType = $StateObject->StateGet(
                ID => $ChildTicket{StateID},
            )->{Type};

            if ( $ChildStateType ne 'closed' ) {
                $AllClosed = 0;
                last;
            }
        }

        if ($AllClosed) {
            $TicketObject->TicketStateSet(
                TicketID => $ParentID,
                State    => $TargetState,
                UserID   => 1,
            );
        }
    }

    return 1;
}

1;
