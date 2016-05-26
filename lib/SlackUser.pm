# -*- Mode: perl; indent-tabs-mode: nil -*-
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

use strict;
package Bugzilla::Extension::SlackBugz::SlackUser;

use base qw(Bugzilla::Object);
use Bugzilla::Constants;
use Bugzilla::User;
use Bugzilla::Util qw(trim);
use Bugzilla::Error;

use constant DB_TABLE => 'slackbugz_usermap';

use constant DB_COLUMNS => qw(
    id
    slack_id
    user_id
);

use constant LIST_ORDER => 'slack_id';

use constant NUMERIC_COLUMNS => qw(
    user_id
);

use constant UPDATE_COLUMNS => qw(
    slack_id
    user_id
);

use constant VALIDATORS => {
    slack_id => \&_check_slack_id,
    user_id => \&_check_user_id,
};

=head1 METHODS

=head2 Accessors

=cut

sub user_id  { return $_[0]->{user_id}; }
sub slack_id  { return $_[0]->{slack_id}; }

=item C<user> - Get the L<Bugzilla::User> object associated by slackuser->user_id

=cut

sub user {
    my $self = shift;
    $self->{user} ||= Bugzilla::User->new($self->user_id);
    return $self->{user};
}

=back

=head2 Mutators

=cut

sub set_slack_id { $_[0]->set('slack_id', $_[1]); }
sub set_user_id  { $_[0]->set('user_id', $_[1]); }

# Validators

sub _check_slack_id {
    my ($invocant, $id) = @_;
    
    $id = trim($id);
#    $id || ThrowUserError("slackbugz_invalid_field", { field => 'slack_id' });
#    ThrowUserError("slackbugz_invalid_field", { field => 'slack_id' })
#        unless ($id =~ /^[A-Z0-9]{8,}$/);

    return $id;
}

sub _check_user_id {
    my ($invocant, $id) = @_;

    ThrowUserError("", { id => $id })
        unless ($id =~ /\d*/);

    ThrowUserError("", { id => $id })
        unless defined Bugzilla::User->new($id);

    return $id;
}

sub map_users {
    my ($self, $slack_id, $user) = @_;
    $user = new Bugzilla::User($user);

    my $dbh = Bugzilla->dbh;

    $dbh->bz_start_transaction();
    my $mapping = $dbh->selectrow_array(
        "SELECT 1 FROM slackbugz_usermap
          WHERE slack_id = ? OR
                user_id = ?",
        undef, ($slack_id, $user->id));
    if (!$mapping) {
        $dbh->do("INSERT INTO slackbugz_usermap
                              (slack_id, user_id)
                       VALUES (?, ?)",
            undef, ($slack_id, $user->id));
    }
    $dbh->bz_commit_transaction();
    return $mapping ? 0 : 1;
}

sub remove_mapping {
    my ($self, $slack, $user) = @_;
    $user = new Bugzilla::User($user);

    my $dbh = Bugzilla->dbh;

    $dbh->bz_start_transaction();
    my $has_mapping = $dbh->selectrow_array(
        "SELECT 1 FROM slackbugz_usermap
          WHERE slack_id = ? AND
                user_id = ?",
        undef, ($slack, $user->id));
    if ($has_mapping) {
        $dbh->do("DELETE FROM slackbugz_usermap
                        WHERE slack_id = ? AND
                              user_id = ?",
            undef, ($slack, $user->id));
    }
    $dbh->bz_commit_transaction();
    return $has_mapping ? 1 : 0;
}

sub exists {
    my ($self, $slack_id) = @_;
    my $dbh = Bugzilla->dbh;

    $dbh->bz_start_transaction();
    my $has_mapping = $dbh->selectrow_array(
        "SELECT 1 FROM slackbugz_usermap
          WHERE slack_id = ?",
        undef, ($slack_id));
    $dbh->bz_commit_transaction();
    return $has_mapping ? 1 : 0;
}

# Overridden Bugzilla::Object methods
#####################################
=back

=head1 RELATED METHODS

=head2 Bugzilla::User object methods

The L<Bugzilla::User> object is also extended to provide easy access to the
Slack user.

    my $slack_user = Bugzilla->user->slack_user;

=over

=item C<slack_user>

    Description: Returns the SlackUser object associated with this user account
    Returns:     Array ref of C<Bugzilla::Extension::SlackBugz::SlackUser> object.

=cut

BEGIN {
    *Bugzilla::User::slack_user = sub {
        my $self = shift;
        return $self->{slack_user} if defined $self->{slack_user};

        my $slack_id = Bugzilla->dbh->selectcol_arrayref(
            "SELECT id FROM slackbugz_usermap
              WHERE user_id = ?", undef, $self->id);

        $self->{slack_user} = Bugzilla::Extension::SlackBugz::SlackUser->new({ id => $slack_id->[0] });

        return $self->{slack_user};
    };
}

1;

__END__

=back

=head1 SEE ALSO

L<Bugzilla::Object>
