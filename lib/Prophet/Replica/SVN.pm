use warnings;
use strict;

package Prophet::Replica::SVN;
use base qw/Prophet::Replica/;
use Params::Validate qw(:all);
use UNIVERSAL::require;

use Data::UUID;

use SVN::Core; use SVN::Ra; use SVN::Delta; use SVN::Repos; use SVN::Fs;


# require rather than use to make them late-binding
require Prophet::Replica::SVN::ReplayEditor;
require Prophet::Replica::SVN::Util;
use Prophet::ChangeSet;
use Prophet::Conflict;

__PACKAGE__->mk_accessors(qw/url ra repo_path repo_handle current_edit _pool/);


use constant scheme => 'svn';


=head2 setup

Open a connection to the SVN source identified by C<$self->url>.

=cut

sub _get_ra {
    my $self = shift;
    my ( $baton, $ref ) = SVN::Core::auth_open_helper( Prophet::Replica::SVN::Util->get_auth_providers );
    my $config = Prophet::Replica::SVN::Util->svnconfig;
    return SVN::Ra->new( url => $self->url, config => $config, auth => $baton, pool => $self->_pool );
}

sub setup {
    my $self = shift;

    $self->_pool(SVN::Pool->new);
    if ( $self->url =~ /^file:\/\/(.*)$/ ) {
        $self->_setup_repo_connection( repository => $1 );
        #$self->state_handle( $self->prophet_handle ); XXX DO THIS RIGHT
    }

    
    $self->ra( $self->_get_ra );
    
    if ( $self->is_resdb ) {

        # XXX: should probably just point to self
        return;
    }

    my $res_url = "svn:" . $self->url;
    $res_url =~ s/(\_res|)$/_res/;
    $self->ressource( __PACKAGE__->new( { url => $res_url, is_resdb => 1 } ) );
}

sub state_handle { return shift }  #XXX TODO better way to handle this?


sub _setup_repo_connection {
    my $self = shift;
    my %args = validate( @_, { repository => 1, db_uuid => 0 } );
    $self->repo_path( $args{'repository'} );
    $self->db_uuid( $args{'db_uuid'} ) if ( $args{'db_uuid'} );
    
    my $repos = eval { SVN::Repos::open( $self->repo_path ); };
    # If we couldn't open the repository handle, we should create it
    if ( $@ && !-d $self->repo_path ) {
        $repos = SVN::Repos::create( $self->repo_path, undef, undef, undef, undef, $self->_pool );
    }
    $self->repo_handle($repos);
    $self->_determine_db_uuid;
    $self->_create_nonexistent_dir( $self->db_uuid );
}


=head2 uuid

Return the replica SVN repository's UUID

=cut

sub uuid {
    my $self = shift;
    return $self->repo_handle->fs->get_uuid;
}

sub most_recent_changeset {
    my $self = shift;
    Carp::cluck unless ($self->ra);
    $self->ra->get_latest_revnum;
}

sub fetch_changeset {
    my $self   = shift;
    my $rev    = shift;
    my $editor = Prophet::Replica::SVN::ReplayEditor->new( _debug => 0 );
    $editor->ra( $self->_get_ra );
    my $pool = SVN::Pool->new_default;

    # This horrible hack is here because I have no idea how to pass custom variables into the editor
    $editor->{revision} = $rev;

    $self->ra->replay( $rev, 0, 1, $editor );
    return $self->_recode_changeset( $editor->dump_deltas, $self->ra->rev_proplist($rev) );

}

sub _recode_changeset {
    my $self      = shift;
    my $entry     = shift;
    my $revprops  = shift;
    my $changeset = Prophet::ChangeSet->new(
        {   sequence_no          => $entry->{'revision'},
            source_uuid          => $self->uuid,
            original_source_uuid => $revprops->{'prophet:original-source'} || $self->uuid,
            original_sequence_no => $revprops->{'prophet:original-sequence-no'} || $entry->{'revision'},
            is_nullification     => ( ( $revprops->{'prophet:special-type'} || '' ) eq 'nullification' ) ? 1 : undef,
            is_resolution        => ( ( $revprops->{'prophet:special-type'} || '' ) eq 'resolution' ) ? 1 : undef,

        }
    );

    # add each node's changes to the changeset
    for my $path ( keys %{ $entry->{'paths'} } ) {
        if ( $path =~ qr|^(.+)/(.*?)/(.*?)$| ) {
            my ( $prefix, $type, $record ) = ( $1, $2, $3 );
            my $change = Prophet::Change->new(
                {   node_type   => $type,
                    node_uuid   => $record,
                    change_type => $entry->{'paths'}->{$path}->{fs_operation}
                }
            );
            for my $name ( keys %{ $entry->{'paths'}->{$path}->{prop_deltas} } ) {
                $change->add_prop_change(
                    name => $name,
                    old  => $entry->{paths}->{$path}->{prop_deltas}->{$name}->{'old'},
                    new  => $entry->{paths}->{$path}->{prop_deltas}->{$name}->{'new'},
                );
            }

            $changeset->add_change( change => $change );

        } else {
            warn "Discarding change to a non-record: $path" if 0;
        }

    }
    return $changeset;
}





=head1 CODE BELOW THIS LINE 

=cut

our $DEBUG = '0';
use Params::Validate qw(:all);



use constant can_read_records => 1;
use constant can_write_records => 1;
use constant can_read_changesets => 1;
use constant can_write_changesets => 1;


=head2 current_root

Returns a handle to the svn filesystem's HEAD

=cut

sub current_root {
    my $self = shift;
    $self->repo_handle->fs->revision_root( $self->repo_handle->fs->youngest_rev );
}

use constant USER_PROVIDED_DB_UUID => 1;
use constant DETECTED_DB_UUID      => 2;
use constant CREATED_DB_UUID       => 3;

sub _determine_db_uuid {
    my $self = shift;
    return USER_PROVIDED_DB_UUID if $self->db_uuid;
    my @known_replicas = keys %{ $self->current_root->dir_entries("/") };

    for my $key ( keys %{ $self->current_root->dir_entries("/") } ) {
        if ( $key =~ /^_prophet-/ ) {
            $self->db_uuid($key);
            return DETECTED_DB_UUID;
        }
    }

    # no luck. create one

    $self->db_uuid( "_prophet-" . Data::UUID->new->create_str() );
    return CREATED_DB_UUID;
}

sub _post_process_integrated_changeset {
    my $self = shift;
    my ($changeset) = validate_pos( @_, { isa => 'Prophet::ChangeSet' } );

    $self->current_edit->change_prop( 'prophet:special-type' => 'nullification' ) if ( $changeset->is_nullification );
    $self->current_edit->change_prop( 'prophet:special-type' => 'resolution' )    if ( $changeset->is_resolution );
}

sub record_changeset_integration {
    my $self = shift;
    my ($changeset) = validate_pos( @_, { isa => 'Prophet::ChangeSet' } );

    $self->_set_original_source_metadata($changeset);
    return $self->SUPER::record_changeset_integration($changeset);

}

sub _set_original_source_metadata {
    my $self = shift;
    my ($changeset) = validate_pos( @_, { isa => 'Prophet::ChangeSet' } );

    $self->current_edit->change_prop( 'prophet:original-source'      => $changeset->original_source_uuid );
    $self->current_edit->change_prop( 'prophet:original-sequence-no' => $changeset->original_sequence_no );
}

sub _create_nonexistent_dir {
    my $self = shift;
    my $dir  = shift;
    my $pool = SVN::Pool->new_default;
    my $root = $self->current_edit ? $self->current_edit->root : $self->current_root;

    unless ( $root->is_dir($dir) ) {
        my $inside_edit = $self->current_edit ? 1 : 0;
        $self->begin_edit() unless ($inside_edit);
        $self->current_edit->root->make_dir($dir);
        $self->commit_edit() unless ($inside_edit);
    }
}




=head2 begin_edit

Starts a new transaction within the replica's backend database. Sets L</current_edit> to that edit object.

Returns $self->current_edit.

=cut

sub begin_edit {
    my $self = shift;
    my $fs   = $self->repo_handle->fs;
    $self->current_edit( $fs->begin_txn( $fs->youngest_rev ) );
    return $self->current_edit;
}

=head2 commit_edit

Finalizes L</current_edit> and sets the 'svn:author' change-prop to the current user.

=cut

sub commit_edit {
    my $self = shift;
    my $txn  = shift;
    $self->current_edit->change_prop( 'svn:author', ( $ENV{'PROPHET_USER'} || $ENV{'USER'} ) );
    $self->current_edit->commit;
    $self->current_edit(undef);

}

=head2 create_node { type => $TYPE, uuid => $uuid, props => { key-value pairs }}

Create a new record of type C<$type> with uuid C<$uuid>  within the current replica.

Sets the record's properties to the key-value hash passed in as the C<props> argument.

If called from within an edit, it uses the current edit. Otherwise it manufactures and finalizes one of its own.

=cut

sub create_node {
    my $self = shift;
    my %args = validate( @_, { uuid => 1, props => 1, type => 1 } );

    $self->_create_nonexistent_dir( join( '/', $self->db_uuid, $args{'type'} ) );

    my $inside_edit = $self->current_edit ? 1 : 0;
    $self->begin_edit() unless ($inside_edit);

    my $file = $self->_file_for( uuid => $args{uuid}, type => $args{'type'} );
    $self->current_edit->root->make_file($file);
    {
        my $stream = $self->current_edit->root->apply_text( $file, undef );

        # print $stream Dumper( $args{'props'} );
        close $stream;
    }
    $self->_set_node_props(
        uuid  => $args{uuid},
        props => $args{props},
        type  => $args{'type'}
    );
    $self->commit_edit() unless ($inside_edit);

}

sub _set_node_props {
    my $self = shift;
    my %args = validate( @_, { uuid => 1, props => 1, type => 1 } );

    my $file = $self->_file_for( uuid => $args{uuid}, type => $args{type} );
    foreach my $prop ( keys %{ $args{'props'} } ) {
        eval { $self->current_edit->root->change_node_prop( $file, $prop, $args{'props'}->{$prop}, undef ) };
        Carp::confess($@) if ($@);
    }
}

=head2 delete_node {uuid => $uuid, type => $type }

Deletes the node C<$uuid> of type C<$type> from the current replica. 

Manufactures its own new edit if C<$self->current_edit> is undefined.

=cut

sub delete_node {
    my $self = shift;
    my %args = validate( @_, { uuid => 1, type => 1 } );

    my $inside_edit = $self->current_edit ? 1 : 0;
    $self->begin_edit() unless ($inside_edit);

    $self->current_edit->root->delete( $self->_file_for( uuid => $args{uuid}, type => $args{type} ) );
    $self->commit_edit() unless ($inside_edit);
    return 1;
}

=head2 set_node_props { uuid => $uuid, type => $type, props => {hash of kv pairs }}


Updates the record of type C<$type> with uuid C<$uuid> to set each property defined by the props hash. It does NOT alter any property not defined by the props hash.

Manufactures its own current edit if none exists.

=cut

sub set_node_props {
    my $self = shift;
    my %args = validate( @_, { uuid => 1, props => 1, type => 1 } );

    my $inside_edit = $self->current_edit ? 1 : 0;
    $self->begin_edit() unless ($inside_edit);

    my $file = $self->_file_for( uuid => $args{uuid}, type => $args{'type'} );
    $self->_set_node_props(
        uuid  => $args{uuid},
        props => $args{props},
        type  => $args{'type'}
    );
    $self->commit_edit() unless ($inside_edit);

}

=head2 get_node_props {uuid => $uuid, type => $type, root => $root }

Returns a hashref of all properties for the record of type $type with uuid C<$uuid>.

'root' is an optional argument which you can use to pass in an alternate historical version of the replica to inspect.  Code to look at the immediately previous version of a record might look like:

    $handle->get_node_props(
        type => $record->type,
        uuid => $record->uuid,
        root => $self->repo_handle->fs->revision_root( $self->repo_handle->fs->youngest_rev - 1 )
    );


=cut

sub get_node_props {
    my $self = shift;
    my %args = validate( @_, { uuid => 1, type => 1, root => undef } );
    my $root = $args{'root'} || $self->current_root;
    return $root->node_proplist( $self->_file_for( uuid => $args{'uuid'}, type => $args{'type'} ) );
}

=head2 _file_for { uuid => $UUID, type => $type }

Returns a file path within the repository (starting from the root)

=cut

sub _file_for {
    my $self = shift;
    my %args = validate( @_, { uuid => 1, type => 1 } );
    Carp::cluck unless $args{uuid};
    my $file = join( "/", $self->_directory_for_type( type => $args{'type'} ), $args{'uuid'} );
    return $file;

}

sub _directory_for_type {
    my $self = shift;
    my %args = validate( @_, { type => 1 } );
    Carp::cluck unless defined $args{type};
    return join( "/", $self->db_uuid, $args{'type'} );

}

=head2 node_exists {uuid => $uuid, type => $type, root => $root }

Returns true if the node in question exists. False otherwise

=cut

sub node_exists {
    my $self = shift;
    my %args = validate( @_, { uuid => 1, type => 1, root => undef } );

    my $root = $args{'root'} || $self->current_root;
    return $root->check_path( $self->_file_for( uuid => $args{'uuid'}, type => $args{'type'} ) );

}

=head2 enumerate_nodes { type => $type }

Returns a reference to a list of all the records of type $type

=cut

sub enumerate_nodes {
    my $self = shift;
    my %args = validate( @_ => { type => 1 } );
    return [ keys %{ $self->current_root->dir_entries( $self->db_uuid . '/' . $args{type} . '/' ) } ];
}

=head2 enumerate_types

Returns a reference to a list of all the known types in your Prophet database

=cut

sub enumerate_types {
    my $self = shift;
    return [ keys %{ $self->current_root->dir_entries( $self->db_uuid . '/' ) } ];
}


=head2 type_exists { type => $type }

Returns true if we have any nodes of type C<$type>

=cut


sub type_exists {
    my $self = shift;
    my %args = validate( @_, { type => 1, root => undef } );

    my $root = $args{'root'} || $self->current_root;
    return $root->check_path( $self->_directory_for_type( type => $args{'type'}, ) );

}

1;

