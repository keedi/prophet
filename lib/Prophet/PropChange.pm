package Prophet::PropChange;

# ABSTRACT: A single property change.

use Any::Moose;

=attr name

The name of the property we're talking about.

=cut
has name => (
    is  => 'rw',
    isa => 'Str',
);

=attr old_value

What L</name> changed I<from>.

=cut
has old_value => (
    is  => 'rw',
    isa => 'Str|Undef',
);

=head2 new_value

What L</name> changed I<to>.

=cut
has new_value => (
    is  => 'rw',
    isa => 'Str|Undef',
);

sub summary {
    my $self = shift;
    my $name = $self->name || '(property name missing)';
    my $old  = $self->old_value;
    my $new  = $self->new_value;

    if (!defined($old)) {
        return qq{+ "$name" set to "} . ($new || '') . qq{"};
    } elsif (!defined($new)) {
        return qq{- "$name" "$old" deleted.};
    }

    return qq{> "$name" changed from "$old" to "$new".};
}

__PACKAGE__->meta->make_immutable;
no Any::Moose;

1;

=head1 DESCRIPTION

This class encapsulates a single property change.
