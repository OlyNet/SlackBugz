# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::SlackBugz::Params;

use strict;
use warnings;

use Bugzilla::Config::Common;

sub get_param_list {
    return (
        {
            name => 'SlackBotToken',
            desc => 'The token of the Slack bot user generated for your team',
            type => 't',
            required => 1
        },
        {
            name    => 'SlackNewBugMessage',
            desc    => 'A message displayed when a new bug was created (shown above the bug details)',
            type    => 't',
            default => 'A new bug has been created',
        },
        {
            name    => 'SlackDirectMessages',
            desc    => 'Whether to send direct messages to a user in Slack if  a mapping between Slack users and BugZilla users exist.',
            type    => 'b',
            default => 1,
        },
        {
            name    => 'SlackIncludeComment',
            desc    => 'Set this to "On" in order to attach the bug\'s description in Slack message.',
            type    => 'b',
            default => 1,
        },
        {
            name    => 'SlackDefaultColor',
            desc    => 'The default color to use when messaging to Slack',
            type    => 't',
            default => 'warning'
        },
        {
            name    => 'SlackDefaultChannel',
            desc    => 'The default channel to post messages to',
            type    => 't',
            default => '#general'
        },
        {
            name => 'SlackBotName',
            desc => 'The name of bot posting to Slack. Overrides settings in web hook config. ',
            type    => 't',
            default => 'BugZilla',
        }
    );
}

1;
