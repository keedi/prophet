use warnings;
use strict;

package Prophet::Handle;
use base 'Class::Accessor';
use Params::Validate;
use Data::Dumper;
use Data::UUID;

our $DEBUG = 0;


use constant db_root => '_prophet';

=head2 new { repository => $FILESYSTEM_PATH}
 
Create a new subversion filesystem backend repository handle. If the repository don't exist, create it.

=cut

sub new {
    my $class = shift;
    use Prophet::Handle::SVN;
    return Prophet::Handle::SVN->new(@_);
}


=head2 integrate_changeset L<Prophet::ChangeSet>

Given a L<Prophet::ChangeSet>, integrates each and every change within that changeset into the handle's replica.

This routine also records that we've seen this changeset (and hence everything before it) from both the peer who sent it to us AND the replica who originally created it.


=cut

sub integrate_changeset {
    my $self      = shift;
    my $changeset = shift;

    $self->begin_edit();
    $self->record_changeset($changeset);

    $self->_set_original_source_metadata($changeset);
    warn "to commit... " if ($DEBUG);
    my $changed = $self->current_edit->root->paths_changed;
    warn Dumper($changed) if ($DEBUG);
    $self->record_changeset_integration($changeset);
    $self->commit_edit();
}

sub record_resolutions {
    my $self       = shift;
    my $changeset  = shift;
    my $res_handle = shift;

    return unless $changeset->changes;

    $self->begin_edit();
    $self->record_changeset($changeset);

    warn "to commit... " if ($DEBUG);
    my $changed = $self->current_edit->root->paths_changed;
    warn Dumper($changed) if ($DEBUG);

    $res_handle->record_resolution($_) for $changeset->changes;
    $self->commit_edit();
}

=head2 record_resolution

Called ONLY on local resolution creation. (Synced resolutions are just synced as records)

=cut

sub record_resolution {
    my ( $self, $change ) = @_;

    return 1 if $self->node_exists(
        uuid => $self->uuid,
        type => '_prophet_resolution-' . $change->resolution_cas
    );

    $self->create_node(
        uuid  => $self->uuid,
        type  => '_prophet_resolution-' . $change->resolution_cas,
        props => {
            _meta => $change->change_type,
            map { $_->name => $_->new_value } $change->prop_changes
        }
    );
}

sub record_changeset {
    my $self      = shift;
    my $changeset = shift;

    eval {

        my $inside_edit = $self->current_edit ? 1 : 0;
        $self->begin_edit() unless ($inside_edit);
        $self->_integrate_change($_) for ( $changeset->changes );
        $self->current_edit->change_prop( 'prophet:special-type' => 'nullification' )
            if ( $changeset->is_nullification );
        $self->current_edit->change_prop( 'prophet:special-type' => 'resolution' ) if ( $changeset->is_resolution );
        $self->commit_edit() unless ($inside_edit);
    };
    die($@) if ($@);
}

sub _set_original_source_metadata {
    my $self   = shift;
    my $change = shift;

    $self->current_edit->change_prop( 'prophet:original-source'      => $change->original_source_uuid );
    $self->current_edit->change_prop( 'prophet:original-sequence-no' => $change->original_sequence_no );
}

sub _integrate_change {
    my $self   = shift;
    my $change = shift;

    my %new_props = map { $_->name => $_->new_value } $change->prop_changes;

    if ( $change->change_type eq 'add_file' ) {
        $self->create_node(
            type  => $change->node_type,
            uuid  => $change->node_uuid,
            props => \%new_props
        );
    } elsif ( $change->change_type eq 'add_dir' ) {
    } elsif ( $change->change_type eq 'update_file' ) {
        $self->set_node_props(
            type  => $change->node_type,
            uuid  => $change->node_uuid,
            props => \%new_props
        );
    } elsif ( $change->change_type eq 'delete' ) {
        $self->delete_node(
            type => $change->node_type,
            uuid => $change->node_uuid
        );
    } else {
        Carp::confess( " I have never heard of the change type: " . $change->change_type );
    }
    
}






our $MERGETICKET_METATYPE = '_merge_tickets';

=head2 record_changeset_integration L<Prophet::ChangeSet>

This routine records the immediately upstream and original source
uuid and sequence numbers for this changeset. Prophet uses this
data to make sane choices about later replay and merge operations


=cut

sub record_changeset_integration {
    my $self = shift;
    my ($changeset) = validate_pos( @_, { isa => 'Prophet::ChangeSet' } );

    # Record a merge ticket for the changeset's "original" source
    $self->_record_merge_ticket( $changeset->original_source_uuid, $changeset->original_sequence_no );

}

sub _record_merge_ticket {
    my $self = shift;
    my ( $source_uuid, $sequence_no ) = validate_pos( @_, 1, 1 );

    my $props = eval { $self->get_node_props( uuid => $source_uuid, type => $MERGETICKET_METATYPE ) };
    unless ( $props->{'last-changeset'} ) {
        eval { $self->create_node( uuid => $source_uuid, type => $MERGETICKET_METATYPE, props => {} ) };
    }

    $self->set_node_props(
        uuid => $source_uuid,
        type => $MERGETICKET_METATYPE,
        props => { 'last-changeset' => $sequence_no }
    );

}




use YAML::Syck;

package YAML;
*Dump = *YAML::Syck::Dump;

1;
