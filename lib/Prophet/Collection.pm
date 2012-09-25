package Prophet::Collection;

# ABSTRACT: Collections of L<Prophet::Record> objects

use Any::Moose;
use Params::Validate;
use Prophet::Record;

use overload '@{}' => sub { shift->items }, fallback => 1;
use constant record_class => 'Prophet::Record';

has app_handle => (
    is       => 'rw',
    isa      => 'Prophet::App|Undef',
    required => 0,
    trigger  => sub {
        my ( $self, $app ) = @_;
        $self->handle( $app->handle );
    },
);

has handle => (
    is  => 'rw',
    isa => 'Prophet::Replica',
);

has type => (
    is      => 'rw',
    isa     => 'Str',
    lazy    => 1,
    default => sub {
        my $self = shift;
        $self->record_class->new( app_handle => $self->app_handle )
          ->record_type;
    },
);

=attr items

Returns a reference to an array of all the items found

=cut

has items => (
    is         => 'rw',
    isa        => 'ArrayRef',
    default    => sub { [] },
    auto_deref => 1,
);

sub count { scalar @{ $_[0]->items } }

sub add_item {
    my $self = shift;
    push @{ $self->items }, @_;
}

=method matching $CODEREF

Find all L<Prophet::Record>s of this collection's C<type> where $CODEREF
returns true.

=cut

sub matching {
    my $self    = shift;
    my $coderef = shift;

    # return undef unless $self->handle->type_exists( type => $self->type );
    # find all items,
    Carp::cluck unless defined $self->type;

    my $records = $self->handle->list_records(
        record_class => $self->record_class,
        type         => $self->type
    );

    # run coderef against each item;
    # if it matches, add it to items
    for my $record (@$records) {
        $self->add_item($record) if ( $coderef->($record) );
    }

    # XXX TODO return a count of items found

}

__PACKAGE__->meta->make_immutable;
no Any::Moose;

1;

=head1 DESCRIPTION

This class allows the programmer to search for L<Prophet::Record> objects
matching certain criteria and to operate on those records as a collection.
