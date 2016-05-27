# -*- Mode: perl; indent-tabs-mode: nil -*-
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

use strict;
package Bugzilla::Extension::SlackBugz::SlackChannel;

use base qw(Bugzilla::Object);
use Bugzilla::Constants;
use Bugzilla::User;
use Bugzilla::Util qw(trim);
use Bugzilla::Error;
use List::Util qw(first);

use constant DB_TABLE => 'slackbugz_channels';

use constant DB_COLUMNS => qw(
    id
    channel_id
);

use constant LIST_ORDER => 'id';

use constant UPDATE_COLUMNS => qw(
    channel_id
);

use constant VALIDATORS => {
    channel_id => \&_check_channel_id,
};

=head1 METHODS

=head2 Accessors

=cut

sub channel_id  { return $_[0]->{channel_id}; }

=item C<components()>

    Description: Get the L<Bugzilla::Component> objects associated with this channel
    Returns: Array reference of L<Bugzilla::Component> objects

=cut

sub components {
    my $self = shift;
    my $dbh = Bugzilla->dbh;

    if (!defined $self->{components}) {
        my $comp_result = $dbh->selectall_arrayref(
            "SELECT component_id FROM slackbugz_channels_components
                WHERE channel_id = ?",
            undef, $self->id);
        my %components = map { $_->[0] => $_ } @$comp_result;
        $self->{components} = Bugzilla::Component->new_from_list([keys %components]) || [];
    }

    return $self->{components};
}

=item C<add_component($component)
    
    Description: Adds a L<Bugzilla::Component> object to the mapping of this obj
    Returns:

=cut

sub add_component {
    my ($self, $component) = @_;

    ThrowCodeError('param_required', { 
        param => 'component', 
        function => 'SlackChannel->add_component'
    }) unless (defined $component);

    $component = Bugzilla::Component->new($component) unless ref $component;
    ThrowCodeError('param_invalid', {
        param => blessed($component),
        function => 'SlackChannel->add_component'
    }) unless (defined $component);

    return 0 if !$self->components || first { $_->id == $component->id } @{ $self->components };

    my $dbh = Bugzilla->dbh;
    $dbh->bz_start_transaction();
    $dbh->do("INSERT INTO slackbugz_channels_components(channel_id, component_id)
                 VALUES(?, ?)",
        undef, ($self->id, $component->id));
    $dbh->bz_commit_transaction();
    
    push @{ $self->components }, $component;

    foreach my $comp (@{ $self->components }) {
        push @{ $comp->channels }, $self;
    }

    return 1;
}

sub remove_component {
    my ($self, $component) = @_;

    ThrowCodeError('param_required', {
        param => 'component',
        function => 'SlackChannel->add_component'
    }) unless (defined $component);

    $component = Bugzilla::Component->new($component) unless ref $component;
    ThrowCodeError('param_invalid', {
        param => blessed($component),
        function => 'SlackChannel->add_component'
    }) unless (defined $component);

    if (!$self->components || !first { $_->id == $component->id } @{ $self->components }) {
        return 0;
    }

    my $dbh = Bugzilla->dbh;
    $dbh->bz_start_transaction();
    $dbh->do("DELETE FROM slackbugz_channels_components
                 WHERE channel_id = ? AND component_id =?",
        undef, ($self->id, $component->id));
    $dbh->bz_commit_transaction();

    $self->{components} = [grep { $_->id != $component->id } @{ $self->components }];

    foreach my $comp (@{ $self->components }) {
        $comp->{channels} = [grep { $_->id != $self->id } @{ $comp->channels }];
    }

    return 1;
}

sub exists {
    my ($self, $channel_id) = @_;
    my $dbh = Bugzilla->dbh;

    my $has_mapping = $dbh->selectrow_array(
        "SELECT 1 FROM slackbugz_channels
          WHERE channel_id = ?",
        undef, ($channel_id));
    return $has_mapping ? 1 : 0;
}

=back

=cut

# Validators

sub _check_channel_id {
    my ($invocant, $id) = @_;
    
    $id = trim($id);
    $id || ThrowUserError("slackbugz_invalid_field", { field => 'channel_id' });
    ThrowUserError("slackbugz_invalid_field", { field => 'channel_id' })
        unless ($id =~ /^[A-Z0-9]{8,}$/);

    return $id;
}

=back

=head1 RELATED METHODS

=head2 Bugzilla::Component object methods

The L<Bugzilla::User> object is also extended to provide easy access to the
Slack user.

=over

=item C<Bugzilla::Component::channels>

    Description: Returns the channel objects associated with this component
    Returns:     Array ref of C<Bugzilla::Extension::SlackBugz::SlackChannel> object.

=cut

BEGIN {
    *Bugzilla::Component::channels = sub {
        my $self = shift;

        if (!defined $self->{slack_channels}) {
            my $channel_result = Bugzilla->dbh->selectall_arrayref(
                 "SELECT channel_id FROM slackbugz_channels_components
                   WHERE component_id = ?", undef, $self->id);
            my %channels = map { $_->[0] => $_ } @$channel_result;
            $self->{slack_channels} = Bugzilla::Extension::SlackBugz::SlackChannel->new_from_list([keys %channels]);
        }

        return $self->{slack_channels};
    };
}

1;

__END__

=back

=head1 SEE ALSO

L<Bugzilla::Object>
