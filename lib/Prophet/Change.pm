package Prophet::Change;

# ABSTRACT: encapsulates a change to a single record in a Prophet replica.

use Any::Moose;
use Prophet::Meta::Types;
use Prophet::PropChange;
use Params::Validate;

=attr record_type

The record type for the record.

=cut

has record_type => (
    is  => 'rw',
    isa => 'Str',
);

=attr record_uuid

The UUID of the record being changed.

=cut

has record_uuid => (
    is  => 'rw',
    isa => 'Str',
);

=attr change_type

One of C<add_file>, C<add_dir>, C<update_file>, C<delete>.

=cut

has change_type => (
    is  => 'rw',
    isa => 'Prophet::Type::ChangeType',
);

has resolution_cas => (
    is  => 'rw',
    isa => 'Str',
);

=attr is_resolution

A boolean value specifying whether this change represents a conflict resolution
or not.

=cut

has is_resolution => (
    is  => 'rw',
    isa => 'Bool',
);

=attr prop_changes [\@PROPCHANGES]

Returns a list of L<Prophet::PropChange>s associated with this Change. Takes an
optional arrayref to fully replace the set of propchanges.

=cut

has prop_changes => (
    is         => 'rw',
    isa        => 'ArrayRef',
    auto_deref => 1,
    default    => sub { [] },
);

=attr has_prop_changes

Returns true if this change contains any L<Prophet::PropChange>s and false if
it doesn't.

=cut

sub has_prop_changes { scalar @{ $_[0]->prop_changes } }

sub _add_prop_change {
    my $self = shift;
    push @{ $self->prop_changes }, @_;
}

=method new_from_conflict $conflict

Takes a L<Prophet::Conflict> object and creates a Prophet::Change object
representing the conflict resolution.

=cut

sub new_from_conflict {
    my ( $class, $conflict ) = @_;
    my $self = $class->new(
        {
            is_resolution  => 1,
            resolution_cas => $conflict->fingerprint,
            change_type    => $conflict->change_type,
            record_type    => $conflict->record_type,
            record_uuid    => $conflict->record_uuid
        }
    );
    return $self;
}

=method add_prop_change { new => __, old => ___, name => ___ }

Adds a new L<Prophet::PropChange> to this L<Prophet::Change>.

Takes a C<name>, and the C<old> and C<new> values.

=cut

sub add_prop_change {
    my $self = shift;
    my %args = (@_);    # validate is far too heavy to be called here
         # my %args = validate( @_, { name => 1, old => 0, new => 0 } );
    my $change = Prophet::PropChange->new(
        name      => $args{'name'},
        old_value => $args{'old'},
        new_value => $args{'new'},
    );
    $self->_add_prop_change($change);
}

=method as_hash

Returns a reference to a representation of this change as a hash.

=cut

sub as_hash {
    my $self  = shift;
    my $props = {};

    for my $pc ( $self->prop_changes ) {
        $props->{ $pc->name } =
          { old_value => $pc->old_value, new_value => $pc->new_value };
    }

    return {
        record_type  => $self->record_type,
        change_type  => $self->change_type,
        prop_changes => $props,
    };
}

=method as_string ARGS

Returns a string representing this change. If C<$args{header_callback}> is
specified, the string returned from passing C<$self> to the callback is
prepended to the change string before it is returned.

=cut

sub as_string {
    my $self         = shift;
    my %args         = validate( @_, { header_callback => 0, } );
    my $out          = '';
    my @prop_changes = $self->prop_changes;
    return '' if @prop_changes == 0;
    $out .= $args{header_callback}->($self) if ( $args{header_callback} );

    for
      my $summary ( sort grep {defined} ( map { $_->summary } @prop_changes ) )
    {
        $out .= "  " . $summary . "\n";
    }

    return $out;

}

=method new_from_hashref HASHREF

Takes a reference to a hash representation of a change (such as is returned by
L</as_hash> or serialized json) and returns a new Prophet::Change
representation of it.

This method should be invoked as a class method, not an object method.

For example: C<Prophet::Change-E<gt>new_from_hashref($ref_to_change_hash)>

=cut

sub new_from_hashref {
    my $class   = shift;
    my $uuid    = shift;
    my $hashref = shift;
    my $self    = $class->new(
        {
            record_type => $hashref->{'record_type'},
            record_uuid => $uuid,
            change_type => $hashref->{'change_type'},
        }
    );
    for my $prop ( keys %{ $hashref->{'prop_changes'} } ) {
        $self->add_prop_change(
            name => $prop,
            old  => $hashref->{'prop_changes'}->{$prop}->{'old_value'},
            new  => $hashref->{'prop_changes'}->{$prop}->{'new_value'}
        );
    }
    return $self;
}

__PACKAGE__->meta->make_immutable;
no Any::Moose;

1;
