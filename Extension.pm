# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::SlackBugz;

use 5.10.1;
use strict;
use warnings;

use parent qw(Bugzilla::Extension);
use Bugzilla::Constants;
use Bugzilla::Error;
use WebService::Slack::WebApi;
use Bugzilla::User;
use Bugzilla::Util qw(trim);

# This code for this is in ../extensions/SlackBugz/lib/Util.pm
use Bugzilla::Extension::SlackBugz::Util;
use Bugzilla::Extension::SlackBugz::SlackUser;
use Bugzilla::Extension::SlackBugz::SlackChannel;
use Bugzilla::Extension::SlackBugz::SlackColor;

use List::Util qw(first);
use Template::Stash;

use Data::Dumper;

BEGIN {
    $Template::Stash::LIST_OPS->{contains_component} = sub {
        my ($list, $key, $needle) = @_;
        return grep { defined $_ && defined $_->$key && $_->$key == $needle } @$list;
    };
}

our $VERSION = '0.01';

my $token = Bugzilla->params->{'SlackBotToken'};
my $slack = WebService::Slack::WebApi->new(
    token => $token
);

my $domain;

sub db_schema_abstract_schema {
    my ($self, $args) = @_;
    my $schema = $args->{schema};

    $schema->{slackbugz_usermap} = {
        FIELDS => [
            id => {
                TYPE => 'MEDIUMSERIAL',
                NOTNULL => 1,
                PRIMARYKEY => 1
            },
            slack_id => {
                TYPE => 'varchar(10)', 
                NOTNULL => 1,
            },
            user_id => {
                TYPE => 'INT3',
                NOTNULL => 0,
                REFERENCES => {
                    TABLE => 'profiles',
                    COLUMN => 'userid',
                    DELETE => 'CASCADE',
                },
            },
        ],
        INDEXES => [
            slackbugz_user_unique_idx => {
                FIELDS => [qw(user_id)],
                TYPE   => 'UNIQUE',
            },
            slackbugz_slack_unique_idx => {
                FIELDS => [qw(slack_id)],
                TYPE   => 'UNIQUE',
            },
        ],
    };

    $schema->{slackbugz_channels} = {
        FIELDS => [
           id => {
                TYPE => 'MEDIUMSERIAL',
                NOTNULL => 1,
                PRIMARYKEY => 1
            },
            channel_id => {
                TYPE => 'varchar(10)', 
                NOTNULL => 1,
            },
        ],
        INDEXES => [
            slackbugz_channel_unique_idx => {
                FIELDS => [qw(channel_id)],
                TYPE   => 'UNIQUE',
            },
        ],
    };

    $schema->{slackbugz_channels_components} = {
        FIELDS => [
            component_id => {
                TYPE => 'INT3',
                NOTNULL => 1,
                REFERENCES => {
                    TABLE => 'components',
                    COLUMN => 'id',
                    DELETE => 'CASCADE',
                },
            },
            channel_id => {
                TYPE => 'INT3', 
                NOTNULL => 1,
                REFERENCES => {
                    TABLE => 'slackbugz_channels',
                    COLUMN => 'id',
                    DELETE => 'CASCADE',
                },
            },
        ],
        INDEXES => [
            slackbugz_component_channel_unique_idx => {
                FIELDS => [qw(component_id channel_id)],
                TYPE   => 'UNIQUE',
            },
        ],
    };

    $schema->{slackbugz_colormap} = {
        FIELDS => [
            id => {
                TYPE => 'MEDIUMSERIAL',
                NOTNULL => 1,
                PRIMARYKEY => 1
            },
            severity_id => {
                TYPE => 'INT2',
                NOTNULL => 1,
                REFERENCES => {
                    TABLE => 'bug_severity',
                    COLUMN => 'id',
                    DELETE => 'CASCADE',
                },
            },
            color => {
                TYPE => 'varchar(10)', 
                NOTNULL => 1,
            },
        ],
        INDEXES => [
            slackbugz_severity_unique_idx => {
                FIELDS => ['severity_id'],
                TYPE   => 'UNIQUE',
            },
        ],
    };
}

sub _get_slack_domain {
    if (!$domain) {
        $domain = $slack->team->info->{'team'}->{'domain'};
    }
    return $domain;    
}

sub _get_slack_channels {
    my $channels = $slack->channels->list(exclude_archived => 1);
    return $channels->{'channels'};
}

sub _get_slack_username {
    my $slack_id = shift;
    my $r = $slack->users->info({ user => $slack_id });
    ThrowUserError('', {slack_id => $slack_id}) unless $r;
    return $r->{'name'} if $r;
}

sub _get_slack_users {
    return grep { $_->{'name'} !~ /bot$/i } @{ $slack->users->list->{'members'} };
}

sub _get_base_url {
    my $base_url = Bugzilla->params->{'sslbase'} || Bugzilla->params->{'urlbase'};

    if (substr($base_url, length($base_url) - 1, 1) ne '/') {
        $base_url .= '/';
    }

    return $base_url;
}

sub _ensure_slack_users_persisted {
    my @users = shift;

    foreach my $slack_user (@users) {
        if (!Bugzilla::Extension::SlackBugz::SlackUser->exists($slack_user->{'id'})) {
            Bugzilla::Extension::SlackBugz::SlackUser->create({ 
                slack_id => $slack_user->{'id'}
            });
        }
        # TODO: handle deleted Slack IDs
    }    
}

sub _ensure_slack_channels_persisted {
    my $channels = shift;

    foreach my $channel (@$channels) {
        if (!Bugzilla::Extension::SlackBugz::SlackChannel->exists($channel->{'id'})) {
            Bugzilla::Extension::SlackBugz::SlackChannel->create({ 
                channel_id => $channel->{'id'}
            });
        }
        # TODO: handle deleted Slack IDs
    }    
}

sub _post_msg {
    my $message = shift;

    return unless defined($slack);

    $message->{color} ||= 'good';
    $message->{text} ||= undef;
    #$message->{channel} ||= Bugzilla->params->{'SlackDefaultChannel'} || '#general';
    $message->{username} ||= Bugzilla->params->{'SlackBotName'} || 'BugZilla';

    my $msg = $slack->chat->post_message($message);

    if (!$msg->{ok}) {
        ThrowUserError('slackbugz_message_error', {return_message => $msg->{error}});
    }
}

sub _format_new_bug_header_message {
    my ($message, $bug) = @_;
    return $message unless defined $message;
    $message =~ s/\$\{(?:author|reporter)\}/$bug->reporter->real_name/ig;
    $message =~ s/\$\{severity\}/$bug->bug_severity/ig;
    $message =~ s/\$\{priority\}/$bug->priority/ig;
    $message =~ s/\$\{status\}/$bug->status->name/ig;
    return $message;
}

# The following subs will override the hooks and modify the behavior
sub bug_end_of_create {
    my ($self, $args) = @_;
    my $bug = $args->{'bug'};
    my $timestamp = $args->{'timestamp'};
    my $bug_id = $bug->id;
    my $bug_severity = $bug->bug_severity;
    my $bug_priority = $bug->priority;
    my $base_url = _get_base_url();
    my $new_bug_message = Bugzilla->params->{'SlackNewBugMessage'} || undef;
    my $bug_link = $base_url.'show_bug.cgi?id='.$bug_id;
    my $slack_color = $bug->slack_color->color || Bugzilla->params->{'SlackDefaultColor'} || 'warning';

    my $message = {
        channel => '',
        username => Bugzilla->params->{'SlackBotName'} || 'BugZilla',
        icon_url => $base_url.'extensions/SlackBugz/web/bz.png',
        as_user => 0,
        text => _format_new_bug_header_message($new_bug_message, $bug),
        attachments => [{
            color => $slack_color,
            title => "#$bug_id: ".$bug->short_desc,
            text => '',
            title_link => $bug_link
        }]
    };

    if (Bugzilla->params->{'SlackIncludeComment'} && scalar @{ $bug->comments }) {
        $message->{attachments}->[0]->{text} => $bug->comments->[0]->body;
    }

    # If users shall be notified by direct messages, get the ID of the assignee
    # and figure out his name on Slack, if this is configured
    if (Bugzilla->params->{'SlackDirectMessages'} && defined $bug->assigned_to->slack_user) {
        $message->{channel} = _get_slack_username($bug->assigned_to->slack_user->slack_id);
        _post_msg($message) if defined $message->{channel};
    }

    # Since we linked our Slack channels for convenience to Bugzilla::Component,
    # it's now easy to iterate over all channels to be notified
    foreach my $channel (@{ $bug->component_obj->channels }) {
        $message->{channel} = $channel->channel_id;
        _post_msg($message);
    }
}

sub bug_end_of_update {
    my ($self, $args) = @_;
    my ($bug, $old_bug, $timestamp, $changes) =
        @$args{qw(bug old_bug timestamp changes)};

    my $bug_id = $bug->id;
    my $bug_severity = $bug->bug_severity;
    my $bug_priority = $bug->priority;
    my $base_url = _get_base_url();
    my $bug_link = $base_url.'show_bug.cgi?id='.$bug_id;
    my $slack_color = $bug->slack_color->color || Bugzilla->params->{'SlackDefaultColor'} || 'warning';
    my $message = {
        username => Bugzilla->params->{'SlackBotName'} || 'BugZilla',
        icon_url => _get_base_url().'extensions/SlackBugz/web/bz.png',
        as_user => 0,
        #text => $new_bug_message,
        attachments => [{
            color => $slack_color,
            title => "#$bug_id: ".$bug->short_desc,
            text => undef,
            title_link => $bug_link
        }]
    };

    foreach my $field (keys %$changes) {
        my $used_to_be = $changes->{$field}->[0];
        my $now_it_is  = $changes->{$field}->[1];
    }

    my $old_summary = $old_bug->short_desc;

    my $status_message;
    if (my $status_change = $changes->{'bug_status'}) {
        my $old_status = new Bugzilla::Status({ name => $status_change->[0] });
        my $new_status = new Bugzilla::Status({ name => $status_change->[1] });
        $message->{attachments}->[0]->{text} .= "Status: *".$old_status."* \x{2192} *".$new_status."*";
        #if ($new_status->is_open && !$old_status->is_open) {
        #}
        #if (!$new_status->is_open && $old_status->is_open) {
        #    $status_message = "Bug closed!";
        #}
    }

    # If users shall be notified by direct messages, get the ID of the assignee
    # and figure out his name on Slack, if this is configured
    if (Bugzilla->params->{'SlackDirectMessages'} && defined $bug->assigned_to->slack_user) {
        $message->{channel} = _get_slack_username($bug->assigned_to->slack_user->slack_id);
        _post_msg($message);
    }

    # Since we linked our Slack channels for convenience to Bugzilla::Component,
    # it's now easy to iterate over all channels to be notified
    foreach my $channel (@{ $bug->component_obj->channels }) {
        $message->{channel} = $channel->channel_id;
        _post_msg($message);
    }
}

sub config_add_panels {
    my ($self, $args) = @_;

    my $modules = $args->{panel_modules};
    $modules->{SlackBugz} = "Bugzilla::Extension::SlackBugz::Params";
}

# Hook called before the template is shown
sub page_before_template {
    my ($self, $params) = @_;
    my $page_id = $params->{page_id};

    # executed for all "page.cgi" requests
    # We need to decide whether we are responsible here, else stop
    return unless ($page_id =~ /^slackbugz\//);

    # Only authenticated and administrative users may access
    Bugzilla->login(LOGIN_REQUIRED);
    ThrowUserError('auth_failure', {
                group => 'admin',
                action => 'access'
            }) unless Bugzilla->user->in_group('admin');

    # store handles for database and CGI
    my $cgi = Bugzilla->cgi;
    my $dbh = Bugzilla->dbh;

    # This is set once we've hit a button on our forms
    my $action = $cgi->param('action') || '';

    # We will serve multiple pages from this hook, so check which on we're
    # currently on; this is for associating Slack users and BugZilla users
    if ($page_id =~ /usermap/) {
        # Get a fresh view of users from Slack
        # All those users need to have a record in the database
        my @slack_users_api = _get_slack_users();
        _ensure_slack_users_persisted(@slack_users_api);

        # First cache all objects from database
        my %users = map {$_->id => $_}  Bugzilla::User->get_all();
        my %susers = map {$_->id => $_} Bugzilla::Extension::SlackBugz::SlackUser->get_all();
        my $bzusers = [values %users];

        # Execute this block only when the user hit the save button
        if ($action eq 'save_mapping') {
            # Get the lists of the form
            my @form_slack_ids = $cgi->param('slack[]');
            my @form_bz_ids = $cgi->param('bzuser[]');

            # Iterate through both lists (equal length)
            for(my $x = 0; $x < scalar @form_slack_ids; $x++) {
               # bzuser[] == -1 means no mapping i.e. remove the mapping
               $form_bz_ids[$x] = undef if $form_bz_ids[$x] == -1;

               unless ($form_bz_ids[$x] == undef) {
                   # The IDs must be valid, of course
                   ThrowUserError('object_does_not_exist', { id => $form_slack_ids[$x] })
                       unless (defined $susers{$form_slack_ids[$x]});
                   ThrowUserError('object_does_not_exist', { id => $form_bz_ids[$x] })
                       unless (defined $users{$form_bz_ids[$x]});
               }

               # And now update our SlackUser object by setting the BugZilla user ID
               # and persisting the entity to DB
               $susers{$form_slack_ids[$x]}->set_user_id($form_bz_ids[$x]);
               $susers{$form_slack_ids[$x]}->update();
            }
        }

        # Now with the new mappings in place, we can create the model and bind
        # it to the template later
        # We will create a structure with our SlackUser object and some more 
        # information we retrieved from the API
        my $slack_users;
        foreach my $su (@slack_users_api) {
            my $s = first { $_->slack_id eq $su->{'id'} } values %susers;
            if ($s) {
                my $t = {
                    slack_user => $s,
                    nick => $su->{'name'},
                    email => $su->{'profile'}->{'email'},
                    real_name => $su->{'profile'}->{'real_name_normalized'},
                    # We will propose a mapping by email and name
                    suggested_bzuser => first {
                        lc(trim($_->email)) eq lc(trim($su->{'profile'}->{'email'}))
                        || lc(trim($_->name)) eq lc(trim($su->{'profile'}->{'real_name_normalized'}))
                        || $_->extern_id =~ /$su->{'name'}/i
                    } @{ $bzusers }
                };
                push @$slack_users, $t;
            }
        }

        $params->{vars}->{users} = $slack_users;
        my @templist = ({name => '', id => -1});
        push @templist, sort {$a->name cmp $b->name} @{ $bzusers };
        $params->{vars}->{bzusers} = \@templist;
    } elsif ($page_id =~ /channelmap/) {
        my $slack_channels_api = _get_slack_channels();
        _ensure_slack_channels_persisted($slack_channels_api);

        my %channels = map { $_->id => $_ } Bugzilla::Extension::SlackBugz::SlackChannel->get_all();
        my %components = map { $_->id => $_ } Bugzilla::Component->get_all();

        # Execute this block only when the user hit the save button
        if ($action eq 'save_mapping') {
            # Get the lists of the form
            my @form_channel_ids = $cgi->param('channels[]');

            # Iterate through both lists (equal length is assumed)
            for(my $x = 0; $x < scalar @form_channel_ids; $x++) {
                my $channel = $channels{$form_channel_ids[$x]};
                my %form_component_ids = map { $_ => 1 } $cgi->param('components['.$form_channel_ids[$x].'][]');

                foreach my $component_id (keys %components) {
                    if (exists $form_component_ids{$component_id}) {
                        # need to add component
                        $channel->add_component($components{$component_id});
                    } else {
                        # need to remove component
                        $channel->remove_component($components{$component_id});
                    }
                }
            }
        }

        # We only persist the mapping and the Slack ID in the database so we need
        # to lookup the channel name from the API; construct a data structure
        # for the template containing the actual object and the name
        my $slack_channels;
        foreach my $c (@$slack_channels_api) {
            my $t = first { $_->channel_id eq $c->{'id'} } values %channels;
            push @$slack_channels, {
                slack_channel => $t,
                name => $c->{'name'}
            };
        }

	$params->{vars}->{domain} = _get_slack_domain();
        $params->{vars}->{components} = [sort { $a->name cmp $b->name } values %components];
        $params->{vars}->{channels} = $slack_channels;
    } elsif ($page_id =~ /colormap/) {
        my %severities = %{ $dbh->selectall_hashref("select id, value as name, sortkey from bug_severity where isactive = 1", "id") };
        my %colors = map { $_->severity_id => $_ } Bugzilla::Extension::SlackBugz::SlackColor->get_all();

        # Execute this block only when the user hit the save button
        if ($action eq 'save_mapping') {
            # Get the lists of the form
            my @severity_ids = $cgi->param('severity[]');
            my @colors = $cgi->param('color[]');

            # Iterate through both lists (equal length is assumed)
            for(my $x = 0; $x < scalar @severity_ids; $x++) {
                my $severity = $severities{$severity_ids[$x]};
                my $color = $colors[$x];

                if (defined $severity && defined $color) {
                    my $col = $colors{$severity->{id}};
                    if (defined $col) {
                        $col->set_color($color);
                        $col->update();
                    } else {
                        $col = Bugzilla::Extension::SlackBugz::SlackColor->create({ severity_id => $severity->{id}, color => $color });                        
                    }
                }
            }
        }

        %colors = map { $_->severity_id => $_ } Bugzilla::Extension::SlackBugz::SlackColor->get_all();

        $params->{vars}->{severities} = [sort {$a->{sortkey} cmp $b->{sortkey}} values %severities];
        $params->{vars}->{colors} = [values %colors];
    }
}


__PACKAGE__->NAME;
