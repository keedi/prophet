use warnings;
use strict;

package Prophet::Resolver::Failed;
use base qw/Prophet::Resolver/;

sub run {
    my $self = shift;
    my $conflicting_change = shift;
    my $conflict = shift;

    die "The resolution was not resolved. Sorry dude. (Once Prophet works, you should NEVER see this message)";
}

1;