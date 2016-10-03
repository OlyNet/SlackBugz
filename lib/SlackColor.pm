# -*- Mode: perl; indent-tabs-mode: nil -*-
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

use strict;
package Bugzilla::Extension::SlackBugz::SlackColor;

use base qw(Bugzilla::Object);
use Bugzilla::Constants;
use Bugzilla::User;
use Bugzilla::Util qw(trim);
use Bugzilla::Error;

use constant DB_TABLE => 'slackbugz_colormap';

use constant DB_COLUMNS => qw(
    id
    severity_id
    color
);

use constant LIST_ORDER => 'severity_id';

use constant NUMERIC_COLUMNS => qw(
    severity_id
);

use constant UPDATE_COLUMNS => qw(
    severity_id
    color
);

use constant VALIDATORS => {
    severity_id => \&_check_severity_id,
    color => \&_check_color,
};

=head1 METHODS

=head2 Accessors

=cut

sub severity_id  { return $_[0]->{severity_id}; }
sub color  { return $_[0]->{color}; }

=back

=head2 Mutators

=cut

sub set_severity_id { $_[0]->set('severity_id', $_[1]); }
sub set_color  { $_[0]->set('color', $_[1]); }

# Validators

sub _check_severity_id {
    my ($invocant, $id) = @_;
    
    $id = trim($id);
#    $id || ThrowUserError("slackbugz_invalid_field", { field => 'slack_id' });
#    ThrowUserError("slackbugz_invalid_field", { field => 'slack_id' })
#        unless ($id =~ /^[A-Z0-9]{8,}$/);

    return $id;
}

sub _check_color {
    my ($invocant, $color) = @_;
    $color = trim($color);

    ThrowUserError('slackbugz_invalid_color', { color => $color })
        unless ($color =~ /^(?:#?[a-f0-9]{6}|good|warning|danger)$/i);

    return $color;
}

# Overridden Bugzilla::Object methods
#####################################
=back

=head1 RELATED METHODS

=head2 Bugzilla::Bug object methods

The L<Bugzilla::Bug> object is also extended to provide easy access to the
color of the message in Slack.

    my $slack_color = $bug->slack_color;

=over

=item C<slack_color>

    Description: Returns the SlackColor object associated with this bug instance
    Returns:     

=cut

BEGIN {
    *Bugzilla::Bug::slack_color = sub {
        my $self = shift;
        return $self->{slack_color} if defined $self->{slack_color};

        my $slack_color_id = Bugzilla->dbh->selectcol_arrayref(
            "SELECT c.id FROM bugs b
              JOIN bug_severity s ON b.bug_severity = s.value
              JOIN slackbugz_colormap c ON s.id = c.severity_id
              WHERE b.bug_id = ?", undef, $self->id);

        $self->{slack_color} = Bugzilla::Extension::SlackBugz::SlackColor->new({ id => $slack_color_id->[0] });

        return $self->{slack_color};
    };
}

1;

__END__

=back

=head1 SEE ALSO

L<Bugzilla::Object>
