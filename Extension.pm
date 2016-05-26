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

use List::Util qw(first);

use Data::Dumper;

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

sub _get_slack_users {
    return grep { $_->{'name'} !~ /bot$/i } @{ $slack->users->list->{'members'} };
}

sub _post_msg {
    my ($channel, $title, $link, $color) = @_;

    return unless defined($slack);

    $color = $color || 'good';
    $channel = $channel || Bugzilla->params->{'SlackDefaultChannel'} || '#general';
    my $username = Bugzilla->params->{'SlackBotName'} || 'BugZilla';

    my $msg = $slack->chat->post_message(
        channel => $channel,
        #'text' => $head,
        color => $color,
        # 'icon_url' => $icon_url
        username => $username,
        as_user => 0,
        attachments => [
            title => $title,
            title_link => $link#,
            #'text' => ''
        ]
    );
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
    }    
}

# The following subs will override the hooks and modify the behavior
sub bug_end_of_create {
    my ($self, $args) = @_;
    my $bug = $args->{'bug'};
    my $timestamp = $args->{'timestamp'};
    my $bug_id = $bug->id;
    my $base_url = _get_base_url();

    my $text = '<'.$base_url.'show_bug.cgi?id='.$bug_id.'|#'.$bug_id.' '.$bug->short_desc.'>';

   _post_msg('#sysadmin', $bug->short_desc, $base_url.'show_bug.cgi?id='.$bug_id, 'warning');
}

sub bug_end_of_update {
    my ($self, $args) = @_;
    my ($bug, $old_bug, $timestamp, $changes) =
        @$args{qw(bug old_bug timestamp changes)};

    foreach my $field (keys %$changes) {
        my $used_to_be = $changes->{$field}->[0];
        my $now_it_is  = $changes->{$field}->[1];
    }

    my $old_summary = $old_bug->short_desc;

    my $status_message;
    if (my $status_change = $changes->{'bug_status'}) {
        my $old_status = new Bugzilla::Status({ name => $status_change->[0] });
        my $new_status = new Bugzilla::Status({ name => $status_change->[1] });
        if ($new_status->is_open && !$old_status->is_open) {
            $status_message = "Bug re-opened!";
        }
        if (!$new_status->is_open && $old_status->is_open) {
            $status_message = "Bug closed!";
        }
    }

    my $bug_id = $bug->id;
    my $num_changes = scalar keys %$changes;
    my $result = "There were $num_changes changes to fields on bug $bug_id"
                 . " at $timestamp.";
    # Uncomment this line to see $result in your webserver's error log whenever
    # you update a bug.
    # warn $result;
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

        # Get the lists of the form
        my @form_slack_ids = $cgi->param('slack[]');
        my @form_bz_ids = $cgi->param('bzuser[]');

        # Execute this block only when the user hit the save button
        if ($action eq 'save_mapping') {
            # Iterate through both lists (equal length)
            for(my $x = 0; $x < scalar @form_slack_ids; $x++) {
               # bzuser[] == -1 means no mapping so skip this one
               next if $form_bz_ids[$x] == -1;

               # The IDs must be valid, of course
               ThrowUserError('object_does_not_exist', { id => $form_slack_ids[$x] })
                   unless (defined $susers{$form_slack_ids[$x]});
               ThrowUserError('object_does_not_exist', { id => $form_bz_ids[$x] })
                   unless (defined $users{$form_bz_ids[$x]});

               # And now update our SlackUser object by setting the BugZilla user ID
               # and persisting the entity to DB
               $susers{$form_slack_ids[$x]}->set_user_id(int($form_bz_ids[$x]));
               $susers{$form_slack_ids[$x]}->update();
            }
        }

        # Now with the new mappings in place, we can create the model and bind
        # it to the template later
        # We will create a structure with our SlackUser object and some more 
        # information we retrieved from the API
        my $slack_users;
        foreach my $su (@slack_users_api) {
            my $s = Bugzilla::Extension::SlackBugz::SlackUser->match({ slack_id => $su->{'id'} });
            if ($s) {
                my $t = {
                    slack_user => $s->[0],
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
	$params->{vars}->{domain} = _get_slack_domain();
        $params->{vars}->{channels} = _get_slack_channels();
    }
}


__PACKAGE__->NAME;
