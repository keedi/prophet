package Prophet::ForeignReplica;

# ABSTRACT: Base for 2nd-class replicas

use Any::Moose;
use Params::Validate qw(:all);
extends 'Prophet::Replica';

sub fetch_local_metadata {
    my $self = shift;
    my $key  = shift;
    return $self->app_handle->handle->fetch_local_metadata(
        $self->uuid . "-" . $key );
}

sub store_local_metadata {
    my $self  = shift;
    my $key   = shift;
    my $value = shift;
    return $self->app_handle->handle->store_local_metadata(
        $self->uuid . "-" . $key => $value );
}

sub conflicts_from_changeset { return; }
sub can_write_changesets     {1}

sub record_resolutions {
    die "Resolution handling is not for foreign replicas";
}

sub import_resolutions_from_remote_source {
    warn 'resdb not implemented yet';
    return;
}

=method record_changes L<Prophet::ChangeSet>

Integrate all changes in this changeset.

=cut

sub record_changes {
    my $self = shift;
    my ($changeset) = validate_pos( @_, { isa => 'Prophet::ChangeSet' } );
    $self->integrate_changes($changeset);
}

# XXX TODO = or do these ~always stay stubbed?
sub begin_edit  { }
sub commit_edit { }

# foreign replicas never have a db uuid
sub db_uuid {return}

sub uuid_for_url {
    my ( $self, $url ) = @_;
    return $self->uuid_generator->create_string_from_url($url);
}

=method prompt_for_login

Interactively prompt the user for a username and an authentication secret
(usually a password).

Named parameters:

=for :list
* uri
* username
* password
* username_prompt
* secret_prompt

To use the default prompts, which ask for a username and password, pass in
C<uri> and (optionally) C<username>.  Either prompt will be skipped if a value
is passed in to begin, making this suitable for use in a login loop that
prompts for values and then tests that they work for authentication, looping
around if they don't.

You can also override the default prompts by passing in subroutines for
C<username_prompt> and/or C<secret_prompt>. These subroutines return strings to
be printed and are called like this:

    username_prompt( uri )
    secret_prompt( uri, username )

Where C<uri> and C<username> are the args that are passed in under those names
(if any). You don't need to use them; use a closure if you want something else.

=cut

sub prompt_for_login {
    my $self = shift;
    my %args = (
        uri           => undef,
        username      => undef,
        password      => undef,
        secret_prompt => sub {
            my ( $uri, $username ) = @_;
            return "Password for $username: @ $uri: ";
        },
        username_prompt => sub {
            my ($uri) = shift;
            return "Username for ${uri}: ";
        },
        @_,
    );

    # check if username and password are in config
    my $replica_username_key =
      'replica.' . $self->scheme . ":" . $self->{url} . '.username';
    my $replica_token_key =
      'replica.' . $self->scheme . ":" . $self->{url} . '.secret_token';

    if ( !$args{username} ) {
        my $check_username =
          $self->app_handle->config->get( key => $replica_username_key );
        $args{username} = $check_username if $check_username;
    }

    my $was_in_pager = Prophet::CLI->in_pager();
    Prophet::CLI->end_pager();

    # XXX belongs to some CLI callback
    use Term::ReadKey;
    local $| = 1;
    unless ( $args{username} ) {
        print $args{username_prompt}( $args{uri} );
        ReadMode 1;
        chomp( $args{username} = ReadLine 0 );
    }

    if ( my $check_password =
        $self->app_handle->config->get( key => $replica_token_key ) )
    {
        $args{password} = $check_password;
    } elsif ( !defined( $args{password} ) ) {
        print $args{secret_prompt}( $args{uri}, $args{username} );
        ReadMode 2;
        chomp( $args{password} = ReadLine 0 );
        ReadMode 1;
        print "\n";
    }
    Prophet::CLI->start_pager() if ($was_in_pager);

    return ( $args{username}, $args{password} );
}

sub log {
    my $self = shift;
    my ($msg) = validate_pos( @_, 1 );
    Carp::confess unless ( $self->app_handle );
    $self->app_handle->log( $self->url . ": " . $msg );
}

no Any::Moose;
__PACKAGE__->meta->make_immutable;

1;

=head1 DESCRIPTION

This abstract baseclass implements the helpers you need to be able to easily
sync a prophet replica with a "second class citizen" replica which can't
exactly reconstruct changesets, doesn't use uuids to track records and so on.
