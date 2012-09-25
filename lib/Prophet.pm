# ABSTRACT: A distributed database system
use warnings;
use strict;

package Prophet;

1;

=head1 DESCRIPTION

Prophet is a distributed database system designed for small to medium scale
social database applications.  Our early targets include things such as bug
tracking.

=head2 Design goals

=for :list
* Arbitrary record schema
* Replication
* Disconnected operation
* Peer to peer synchronization

=head2 Design constraints

=over

=item Scaling

We don't currently intend for the first implementation of Prophet to scale to
databases with millions of rows or hundreds of concurrent users. There's
nothing that makes the design infeasible, but the infrastructure necessary for
such a system will...needlessly hamstring it.

=back
