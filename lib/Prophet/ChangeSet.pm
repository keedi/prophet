package Prophet::ChangeSet;

# ABSTRACT: represents a single, atomic Prophet database update.

use Any::Moose;
use Prophet::Change;
use Params::Validate;
use Digest::SHA qw/sha1_hex/;
use JSON;

=attr creator

A string representing who created this changeset.

=cut

has creator => (
    is  => 'rw',
    isa => 'Str|Undef',
);

=attr created

A string representing the ISO 8601 date and time when this changeset was
created (UTC).

=cut

has created => (
    is      => 'rw',
    isa     => 'Str|Undef',
    default => sub {
        my ( $sec, $min, $hour, $day, $month, $year ) = gmtime;
        $year += 1900;
        $month++;
        return sprintf '%04d-%02d-%02d %02d:%02d:%02d',
          $year, $month, $day,
          $hour, $min,   $sec;
    },
);

=attr source_uuid

The uuid of the replica sending us the change.

=cut

has source_uuid => (
    is  => 'rw',
    isa => 'Str|Undef',
);

=attr sequence_no

The changeset's sequence number (in subversion terms, revision #) on the
replica sending us the changeset.

=cut

has sequence_no => (
    is  => 'rw',
    isa => 'Int|Undef',
);

=attr original_source_uuid

The uuid of the replica where the change was authored.

=cut

has original_source_uuid => (
    is  => 'rw',
    isa => 'Str',
);

=attr original_sequence_no

The changeset's sequence number (in subversion terms, revision #) on the
replica where the change was originally created.

=cut

has original_sequence_no => (
    is  => 'rw',
    isa => 'Int|Undef',
);

=head2 is_nullification

A boolean value specifying whether this is a nullification changeset or not.

=cut

has is_nullification => (
    is  => 'rw',
    isa => 'Bool',
);

=attr is_resolution

A boolean value specifying whether this is a conflict resolution changeset or
not.

=cut

has is_resolution => (
    is  => 'rw',
    isa => 'Bool',
);

=attr changes

Returns an array of all the changes in the current changeset.

=cut

has changes => (
    is         => 'rw',
    isa        => 'ArrayRef',
    auto_deref => 1,
    default    => sub { [] },
);

has sha1 => (
    is  => 'rw',
    isa => 'Maybe[Str]'
);

=head2 has_changes

Returns true if this changeset has any changes.

=cut

sub has_changes { scalar @{ $_[0]->changes } }

sub _add_change {
    my $self = shift;
    push @{ $self->changes }, @_;
}

=method add_change { change => L<Prophet::Change> }

Adds a new change to this changeset.

=cut

sub add_change {
    my $self = shift;
    my %args = validate( @_, { change => { isa => 'Prophet::Change' } } );
    $self->_add_change( $args{change} );

}

our @SERIALIZE_PROPS = (
    qw(creator created sequence_no source_uuid original_source_uuid original_sequence_no is_nullification is_resolution)
);

=method as_hash

Returns a reference to a representation of this changeset as a hash, containing
all the properties in the package variable C<@SERIALIZE_PROPS>, as well as a
C<changes> key containing hash representations of each change in the changeset,
keyed on UUID.

=cut

sub as_hash {
    my $self = shift;
    my $as_hash = { map { $_ => $self->$_() } @SERIALIZE_PROPS };

    for my $change ( $self->changes ) {
        $as_hash->{changes}->{ $change->record_uuid } = $change->as_hash;
    }

    return $as_hash;
}

=method new_from_hashref HASHREF

Takes a reference to a hash representation of a changeset (such as is returned
by L</as_hash> or serialized json) and returns a new Prophet::ChangeSet
representation of it.

Should be invoked as a class method, not an object method.

For example:
C<Prophet::ChangeSet-E<gt>new_from_hashref($ref_to_changeset_hash)>

=cut

sub new_from_hashref {
    my $class   = shift;
    my $hashref = shift;
    my $self =
      $class->new( { map { $_ => $hashref->{$_} } @SERIALIZE_PROPS } );

    for my $change ( keys %{ $hashref->{changes} } ) {
        $self->add_change(
            change => Prophet::Change->new_from_hashref(
                $change => $hashref->{changes}->{$change}
            )
        );
    }
    return $self;
}

=method as_string ARGS

Returns a single string representing the changes in this changeset.

If C<$args{header_callback}> is defined, the string returned from passing
C<$self> to the callback is prepended to the changeset string before it is
returned (instead of L</description_as_string>).

If C<$args{skip_empty}> is defined, an empty string is returned if the
changeset contains no changes.

The argument C<change_filter> can be used to filter certain changes from the
string representation; the function is passed a change and should return false
if that change should be skipped.

The C<change_header> argument, if present, is passed to
C<$change-E<gt>to_string> when individual changes are converted to strings.

=cut

sub as_string {
    my $self = shift;
    my %args = validate(
        @_,
        {
            change_filter    => 0,
            change_header    => 0,
            change_formatter => undef,
            header_callback  => 0,
            skip_empty       => 0
        }
    );

    my $body = '';

    for my $change ( $self->changes ) {
        next if $args{change_filter} && !$args{change_filter}->($change);
        if ( $args{change_formatter} ) {
            $body .=
              $args{change_formatter}
              ->( change => $change, header_callback => $args{change_header} );
        } else {
            $body .=
              $change->as_string( header_callback => $args{change_header} )
              || next;
            $body .= "\n";
        }
    }

    return '' if !$body && $args{'skip_empty'};

    my $header =
        $args{header_callback}
      ? $args{header_callback}->($self)
      : $self->description_as_string;
    my $out = $header . $body;
    return $out;
}

=method description_as_string

Returns a string representing a description of this changeset.

=cut

sub description_as_string {
    my $self = shift;
    sprintf " %s at %s\t\(%d@%s)\n",
      ( $self->creator || '(unknown)' ),
      $self->created,
      $self->original_sequence_no,
      $self->original_source_uuid;
}

sub created_as_rfc3339 {
    my $self = shift;
    my $c    = $self->created;
    $c =~ s/ /T/;
    return $c . "Z";
}

sub calculate_sha1 {
    my $self = shift;
    return sha1_hex( $self->canonical_json_representation );
}

sub canonical_json_representation {
    my $self           = shift;
    my $hash_changeset = $self->as_hash;

    # These two things should never actually get stored
    delete $hash_changeset->{'sequence_no'};
    delete $hash_changeset->{'source_uuid'};

    return to_json( $hash_changeset,
        { canonical => 1, pretty => 0, utf8 => 1 } );

}

__PACKAGE__->meta->make_immutable;
no Any::Moose;

1;

=head1 DESCRIPTION

This class represents a single, atomic Prophet database update. It tracks some
metadata about the changeset itself and contains a list of L<Prophet::Change>
entries which describe the actual records created, updated and deleted.
