#!/usr/bin/perl -w

use strict;
use warnings;

use POE qw(Component::IRC);
use POE::Component::IRC::Plugin::NickServID;
use WWW::Shorten::TinyURL;
use Regexp::Common qw /URI/;
use DateTime;
use XML::Feed;

use Dialogue;

my %file_of = (
    karma    => 'karma',
    seen     => 'seen',
    messages => 'messages',
    num_msgs => 'num_msgs',
    logs     => 'logs',
    plans    => 'plans',
    trusts   => 'trusts',
);

my $botname = 'zarah';
my $ircname = 'Zarah the Bioclipse bot';
my $server = 'irc.freenode.net';

my @channels = ( '#farmbio', '#ki-twiki', '#bioclipse', '#cdk',
                 '#metware', '#november-wiki', '#perl6-soc' );
my @developers = qw<masak jonalv>;
my $becomeSkynetCost = 1e7;

my $url_shortening_limit = 70;
my (%last_thing_said_on, %repeat_count_on);
my $want_to_restart = '';

my $karma    = load_from_file($file_of{karma});
my $seen     = load_from_file($file_of{seen});
my $messages = load_from_file($file_of{messages});
my $num_msgs = load_from_file($file_of{num_msgs});
my $logs     = load_from_file($file_of{logs});
my $plans    = load_from_file($file_of{plans});
my $trusts   = load_from_file($file_of{trusts});

my $global_greeting = qr[^(hi|moin|y0|hello|ehlo|oh hai|bongiorno|hola|terve)(?:,? all)?!?$]i;
my $inc_karma       = qr[\b([\w]+)\+\+];
my $dec_karma       = qr[\b([\w]+)--];
my $inc_karma_paren = qr[\(([^)]+)\)\+\+];
my $dec_karma_paren = qr[\(([^)]+)\)--];
my $url             = qr[($RE{URI}{HTTP})];
my $bug_number      = qr[(?:bug|fixes|addresses|resolves):? \#?(\d+)]i;
my $cdk_bug_number  = qr[cdk bug:? \#?(\d+)]i;
my $yourcute        = qr[(?:you're|you are) the\s+(.+?)\s+one]i; # ' for vim
my $three_cheers    = qr[^three cheers for (.*)];
my $yourexcused     = qr[^ $botname [,:]? \s* (?:you're|you \s+ are)
                         \s+ excused]x; # '
my $you_should      = qr[ ( .*? you \s+ should .* ) ]x;
my $youreasmartgirl = qr[ ( .*? \b (?:you're|you \s+ are) \s+ a \s+
                         smart \s+ girl \b .* ) ]x; # '
my $address_bot     = qr[^ $botname [,:] (.*) ]x;
my $forgot_swedish  = qr[ (?:aa|ae|oe) .*? (?:aa|ae|oe) ]x;

my @actions = (
    [ $global_greeting,            \&global_greeting                  ],
    [ [qw<hi y0 moin hello
          hey ey>],                \&say_hello                        ],
    [ $inc_karma,                  \&inc_karma                        ],
    [ $dec_karma,                  \&dec_karma                        ],
    [ $inc_karma_paren,            \&inc_karma                        ],
    [ $dec_karma_paren,            \&dec_karma                        ],
    [ [qw<karma>],                 \&report_karma,            'bare'  ],
    [ $url,                        \&shorten_url                      ],
    [ $bug_number,                 \&bug_url                          ],
    [ $cdk_bug_number,             \&cdk_bug_url                      ],
    [ [qw<gist>],                  \&gist_url                         ],
    [ [qw<planet>],                \&planet_url                       ],
    [ [qw<tell>],                  \&tell_message                     ],
    [ [qw<ask>],                   \&ask_message                      ],
    [ [qw<messages massages
          message massage
          msg msgs moosages>],     \&messages                         ],
    [ [qw<clear-messages clear>],  \&clear_messages                   ],
    [ [qw<plan estimate todo>],    \&plan_task                        ],
    [ [qw<unplan un-plan
          deplan de-plan
          untodo un-todo
          detodo de-todo>],        \&unplan_task                      ],
    [ [qw<replan rename retodo
          re-plan re-name
          re-todo>],               \&replan_task                      ],
    [ [qw<start begin commence
          resume>],                \&start_task                       ],
    [ [qw<stop halt pause
          cease desist>],          \&stop_task                        ],
    [ [qw<restart reload
          reboot update>],         \&restart                          ],
    [ [qw<google gg>],             \&google_search,           'bare'  ],
    [ [qw<bcwiki wiki>],           \&bc_wiki_search,                  ],
    [ [qw<pelezilla pele
          pelle pz bug bg>],       \&pelezilla_search,                ],
    [ [qw<ps pelesilla>],          \&did_you_mean_pelezilla,          ],
    [ [qw<seen seeen>],            \&seen                             ],
    [ [qw<slap>],                  \&slap,                    'bare'  ],
    [ [qw<hug embrace>],           \&hug,                     'bare'  ],
    [ [qw<thank thx
       thanx dz tack>],            \&thank                            ],
    [ [qw<thanks>],                \&thanks                           ],
    [ [qw<ping>],                  \&ping_message                     ],
    [ [qw<pong>],                  \&ignore_pong                      ],
    [ [qw<help>],                  \&help                             ],
    [ [qw<welcome wb>],               \&welcome                          ],
    [ [qw<botsnack botbeer>],      \&botsnack,                'bare'  ],
    [ [qw<tutorial tour>],         \&tutorial                         ],
    [ $yourcute,                   \&no_you_are_the_cute_one, 'final' ],
    [ $yourexcused,                \&oh_thank_you,            'final' ],
    [ $you_should,                 \&you_should,              'final' ],
    [ $youreasmartgirl,            \&smart_girl,              'final' ],
    [ $three_cheers,               \&three_cheers,            'final' ],
    [ $forgot_swedish,             \&forgot_swedish,          'final' ],
    [ $address_bot,                \&no_comprende,            'final' ],
);

for my $action ( @actions ) {
  if ( !defined &{$action->[1]} ) {
    $action->[1]->(); # fail now rather than later
  }
}

# We create a new PoCo-IRC object
my $irc = POE::Component::IRC->spawn( 
   nick => $botname,
   ircname => $ircname,
   server => $server,
) or die "Oh noooo! $!";

$irc->plugin_add( 'NickServID', POE::Component::IRC::Plugin::NickServID->new(
    Password => 'ettlosenord'
));

POE::Session->create(
    package_states => [
        main => [ qw(_default _start irc_001 irc_public irc_join irc_msg) ],
    ],
    heap => { irc => $irc },
);

$poe_kernel->run();

sub _start {
    my $heap = $_[HEAP];

    # retrieve our component's object from the heap where we stashed it
    my $irc = $heap->{irc};

    $irc->yield( register => 'all' );
    $irc->yield( connect => { } );
    return;
}

sub irc_001 {
    my $sender = $_[SENDER];

    # Since this is an irc_* event, we can get the component's object by
    # accessing the heap of the sender. Then we register and connect to the
    # specified server.
    my $irc = $sender->get_heap();

    print "Connected to ", $irc->server_name(), "\n";

    # we join our channels
    $irc->yield( join => $_ ) for @channels;
    return;
}

sub add_to_log {
    my ($what, $who, $channel) = @_;

    if ( !exists $logs->{$channel} ) {
        $logs->{$channel} = [];
    }
    my $now = DateTime->now();
    push @{$logs->{$channel}}, "$now <$who> $what";
    save_to_file( $file_of{logs}, $logs );
}

sub utter {
    my ($message, $channel, $irc) = @_;

    $irc->yield( privmsg => $channel => $message );

    add_to_log( $message, $botname, $channel );

    if ( !exists $last_thing_said_on{$channel}
         || $last_thing_said_on{$channel} ne $message ) {

        $repeat_count_on{$channel} = 1;
        $last_thing_said_on{$channel} = $message;
    }
}

sub reply_to {
    my ($sender, $message, $channel, $irc) = @_;

    utter("$sender: $message", $channel, $irc);
}

sub global_greeting {
    my ($dialogue) = @_;

    my $sender = $dialogue->person();
    $dialogue->say()->(pick("hi $sender",
                            "privet $sender",
                            "saluton $sender",
                            "ni hao $sender",
                            "hello $sender, you fantastic person you",
                            "oh hai $sender",
                       )
    );
}

sub say_hello {
    my ($dialogue) = @_;

    my $sender = $dialogue->person();
    $dialogue->say()->("hello $sender :)");
}

sub load_from_file {
    my ($filename) = @_;

    return {} unless -e $filename;
    return eval `cat $filename`;
}

sub save_to_file {
    my ($filename, $data) = @_;

    use Data::Dumper;
    open my $DATAFILE, '>', $filename;
    $Data::Dumper::Terse = 1;
    $Data::Dumper::Indent = 1;
    print {$DATAFILE} Dumper( $data );
}

sub inc_karma {
    my ($dialogue) = @_;

    my $giver = $dialogue->person();
    my $victim = $dialogue->content();

    if ( $dialogue->channel() eq '' ) {
        return;
    }
    if ( $giver eq $victim ) {
        $dialogue->say()->(
            "shame on you, $giver, giving yourself karma like that"
        );
        return;
    }
    ++$karma->{$victim};
    save_to_file( $file_of{karma}, $karma );
}

sub dec_karma {
    my ($dialogue) = @_;

    if ( $dialogue->channel() eq '' ) {
        return;
    }
    my $victim = $dialogue->content();

    --$karma->{$victim};
    save_to_file( $file_of{karma}, $karma );
}

sub report_karma {
    my ($dialogue) = @_;

    my $person = trim($dialogue->content() || $dialogue->person());
    if ( !exists $karma->{$person} ) {
        $karma->{$person} = 0;
    }
    $dialogue->say()->( "$person has a karma of ".$karma->{$person} );
}

sub unsupported {
    my ($dialogue) = @_;

    $dialogue->reply()->(
        "I can't do that; complain with " . join ' and ', @developers
    );
}

sub relay_message {
    my ($dialogue, $method) = @_;

    my $sender = $dialogue->person();
    my $receiver = (split ' ', $dialogue->content())[0] or return;

    if ( $receiver eq $botname ) {
        $dialogue->reply()->( "You are wasting your time, and mine." );
        return;
    }

    if ( $receiver =~ /^CIA-\d\d$/ || $receiver =~ /^ilbot/ ) {
        $dialogue->say()->(
            "I don't talk to other bots. And you should get back to work, "
            . $sender . '.'
        );
        return;
    }

    if ( $method eq 'tell' && $receiver =~ m[me\b] ) {
        my $specifics = $dialogue->content();
        $specifics =~ s/^[^ ]+$//;
        $specifics =~ s/^[^ ]+ //;
        if ($specifics) {
            $dialogue->reply()->( "Unknown syntax, I... I just don't get it." );
            return;
        }
        messages($dialogue);
        return;
    }

    $receiver =~ s/:$//;

    my $message = $dialogue->content();
    $message =~ s/^[^ ]+ //;

    if ( $sender eq $receiver || $sender eq 'me' ) {
        if ( $method eq 'ping' ) {
            $dialogue->reply()->( "Um. Okay. 'Ping'." );
        }
        else {
            $dialogue->reply()->( "You can $method yourself that." );
        }
        return;
    }

    my $now = DateTime->now();

    if ( !exists $messages->{$receiver} ) {
        $messages->{$receiver} = [];
    }
    push @{$messages->{$receiver}}, [ $method, $sender, $message, $now ];
    save_to_file( $file_of{messages}, $messages );

    $dialogue->say()->( "Consider it noted." );
}

sub tell_message {
    relay_message(shift, 'tell');
}

sub ask_message {
    relay_message(shift, 'ask');
}

sub pick {
    my @choices = @_;

    return $choices[rand @choices];
}

sub nice_ago {
    my ($d) = @_;

    my $time_ago = join ' ', ($d->years()   ? ($d->years(),   'y') : ()),
                             ($d->months()  ? ($d->months(),  'm') : ()),
                             ($d->days()    ? ($d->days(),    'd') : ()),
                             ($d->hours()   ? ($d->hours(),   'h') : ()),
                             ($d->minutes() ? ($d->minutes(), 'm') : ()),
                             ($d->seconds() ? ($d->seconds(), 's') : ()),
                             'ago';
    if ($time_ago eq 'ago') {
        $time_ago = 'right now';
    }

    return $time_ago;
}

sub messages {
    my ($dialogue) = @_;

    if ($dialogue->content() =~ /^msg .+/) {
        tell_message($dialogue);
    }

    my $tellee = $dialogue->person();
    my @messages_to_tellee = @{$messages->{$tellee} or []};

    if ( @messages_to_tellee ) {
        for my $message ( @messages_to_tellee ) {
            my ($type, $teller, $message, $timestamp) = @$message;
            my $did = $type eq 'tell' ? 'said'
                    : $type eq 'ask'  ? 'asked'
                    : $type eq 'ping' ? 'pinged'
                    :                   'exclaimed';
            my $reply = "$teller $did $message";
            if (defined $timestamp) {
                my $time_diff = DateTime->now()->subtract_datetime($timestamp);
                $reply = nice_ago($time_diff) . ', ' . $reply;
            }
            $dialogue->reply()->( $reply );
        }
        $messages->{$tellee} = [];
        save_to_file( $file_of{messages}, $messages );
    }
    else {
        $dialogue->reply()->( "You have no new messages." );
    }
}

sub clear_messages {
    my ($dialogue) = @_;

    my $tellee = $dialogue->person();
    $messages->{$tellee} = [];
    save_to_file( $file_of{messages}, $messages );

    $dialogue->reply()->( "Messages cleared." );
}

sub nice_time {
    my ($minutes) = @_;

    if ($minutes < 60) {
        return "$minutes m";
    }
    else {
        my $hours = $minutes/60;
        $minutes %= 60;
        return sprintf "%d h%s", $hours, ($minutes ? " $minutes m" : '');
    }
}

sub list_tasks {
    my ($dialogue, $filter, $prefix) = @_;

    my $sender = $dialogue->person();
    return if !exists $plans->{$sender};

    my $printed_plan = '';
    for my $task (sort keys %{$plans->{$sender}{'tasks'}}) {

        next if defined $prefix && $task !~ m[^\Q$prefix/\E];
        next if !$filter->($task);

        my $planned_time = $plans->{$sender}{'tasks'}{$task}{'planned_time'};
        my $elapsed_time = $plans->{$sender}{'tasks'}{$task}{'elapsed_time'};

        my $current_task_time = 0;
        if (exists $plans->{$sender}{'working_on'}
            && $plans->{$sender}{'working_on'}{'what'} eq $task) {

            $current_task_time = current_task_spent_time($sender);
            $elapsed_time += $current_task_time;
        }

        my $task_info
            = sprintf "%s: %s planned", $task, nice_time($planned_time);
        if ($elapsed_time) {
            $task_info .= sprintf ', %s elapsed', nice_time($elapsed_time);
        }
        if ($current_task_time) {
            $task_info .= sprintf ' (active: %s)',
                                  nice_time($current_task_time);
        }

        ++$printed_plan;
        $dialogue->reply()->( $task_info );
    }

    if (!$printed_plan) {
        my $reply;
        if ( keys %{$plans->{$sender}{'tasks'}} ) {
            $reply = 'No new tasks. Use \'@plan all\' to see all tasks.';
            if ( defined $prefix ) {
                $reply =~ s{\.}{ prefixed '$prefix/'.};
            }
        }
        else {
            $reply = 'No tasks.';
        }
        
        $dialogue->reply()->( $reply );
    }
}

sub check_task_name_validity {
    my ($task_name, $tasks_ref) = @_;

    if ( $task_name !~ m[ ^ [a-zA-Z] ]x ) {
        return "Task names must start with a letter.";
    }
    if ( $task_name !~ m[ [a-zA-Z0-9] $ ]x ) {
        return "Task names must end with an alphanumerical character.";
    }
    if (exists $tasks_ref->{$task_name}) {
        return "A task by the name '$task_name' already exists.";
    }
}

sub plan_task {
    my ($dialogue) = @_;

    my $sender = $dialogue->person();
    if (!exists $plans->{$sender}) {
        $plans->{$sender} = { 'tasks' => {} };
    }
    my $tasks = $plans->{$sender}{'tasks'};

    my $reply;
    my $content = trim($dialogue->content() || '');

    my $current_task = exists $plans->{$sender}{'working_on'}
                       ? $plans->{$sender}{'working_on'}{'what'}
                       : '';

    my $new_filter = sub { !$tasks->{$_[0]}{'elapsed_time'} 
                           && $_[0] ne $current_task };
    my $new_or_active_filter = sub {
        my ($task) = @_;
        !$tasks->{$task}{'elapsed_time'} || $task eq $current_task
    };
    my $old_filter = sub { $tasks->{+shift}{'elapsed_time'} };
    my $last_filter = sub { shift eq $plans->{$sender}{'last_worked_on'} };
    my $all_filter = sub { 1 };

    if ( $content eq '' ) {
        list_tasks( $dialogue, $new_or_active_filter );
        return;
    }
    elsif ( my ($prefix) = $content =~ m[^(\S+)$] ) {
        $prefix =~ s[/*$][];
        if (grep { $_ =~ m[^\Q$prefix/\E] } keys %{$tasks}) {

            list_tasks( $dialogue, $new_or_active_filter, $prefix );
            return;
        }
        else {
            $reply = 'syntax: @plan <task name> <number>h';
        }
    }

    my %filters = (
        'list' => $all_filter,
        'all'  => $all_filter,
        'new'  => $new_filter,
        'old'  => $old_filter,
        'last' => $last_filter,
    );

    for my $directive (keys %filters) {
        my $filter = $filters{$directive};

        my $prefix;
        if ( $content eq $directive ) {
            list_tasks($dialogue, $filter);
            return;
        }
        elsif (    ($prefix) = $content =~ m[^$directive\s+(\S+)$]
                or ($prefix) = $content =~ m[^(\S+)\s+$directive$] ) {

            $prefix =~ s[/*$][];
            if (grep { $_ =~ m[^\Q$prefix/\E] } keys %{$tasks}) {

                list_tasks( $dialogue, $filter, $prefix );
                return;
            }
        }
        else {
            $reply = $directive eq 'list' || $directive eq 'all'
                     ? "You have no tasks prefixed '$prefix/'"
                     : "You have no $directive tasks prefixed '$prefix/'";
        }
    }

    if ( my ($task_name, $hours, $minutes, $seconds) =
            $content =~ m[ ^ \s*             # optional whitespace
                           (\S+)\s+          # task name, mandatory whitespace
                           (?:(\d+)\s*h\s*)? # optional hours specification
                           (?:(\d+)\s*m\s*)? #          minutes
                           (?:(\d+)\s*s\s*)? #          seconds
                           $
                         ]x ) {

        if (!$hours && !$minutes) {
            $dialogue->reply()->( "I don't deal in seconds. Don't be a hero." );
            return;
        }

        if ( my $complaint = check_task_name_validity($task_name, $tasks) ) {
            $dialogue->reply()->( $complaint );
            return;
        }
        $reply = "Planned task '$task_name' for ";
        my $planned_time = 60*$hours + $minutes;

        if ($planned_time > 60*16) {
            $dialogue->reply()->( 'Sorry, no tasks longer than 16 h.' );
            return;
        }

        if ($seconds >= 30) {
            ++$planned_time;
        }
        $reply .= nice_time($planned_time) . '.';
 
        if ($seconds) {
            $reply .= ' I don\'t deal in seconds.';
        }
        $tasks->{$task_name} = { 'planned_time' => 60*$hours + $minutes,
                                 'elapsed_time' => 0 };
        $plans->{$sender}{'last_worked_on'} = $task_name;

        save_to_file( $file_of{plans}, $plans );
    }
    else {
        $reply = 'Syntax: @plan <task name> <number>h';
    }
    $dialogue->reply()->( $reply );
}

sub unplan_task {
    my ($dialogue) = @_;

    my $sender = $dialogue->person();
    if (!exists $plans->{$sender}) {
        $plans->{$sender} = { 'tasks' => {} };
    }
    my $tasks = $plans->{$sender}{'tasks'};

    my $task_name = trim($dialogue->content() || '');

    my $reply;
    if ($task_name eq '') {
        $reply = 'Syntax: @unplan <task name>';
    }
    elsif (!exists $tasks->{$task_name}) {
        $reply = do_fuzzy_thing_with_task_name(
            $tasks,
            $task_name,
            sub {
                $dialogue->content( shift );
                unplan_task( $dialogue );
            }
        );
    }
    elsif ($tasks->{$task_name}{'elapsed_time'}
           || exists $plans->{$sender}{'working_on'}
              && $plans->{$sender}{'working_on'}{'what'} eq $task_name) {

        $reply = 'No can do. You have already spent time on that task.';
    }
    else {
        $reply = "Ok, task '$task_name' removed.";
        delete $tasks->{$task_name};
        delete $plans->{$sender}{'last_worked_on'};
        save_to_file( $file_of{plans}, $plans );
    }

    $dialogue->reply()->( $reply ) if $reply;
}

sub replan_task {
    my ($dialogue) = @_;

    my $sender = $dialogue->person();
    if (!exists $plans->{$sender}) {
        $plans->{$sender} = { 'tasks' => {} };
    }
    my $tasks = $plans->{$sender}{'tasks'};

    my ($old_name, $new_name) = split /\s+/, trim($dialogue->content() || '');

    my $reply;
    if ($new_name eq '') {
        $reply = 'Syntax: @replan <task name> <new task name>';
    }
    elsif (!exists $tasks->{$old_name}) {
        $reply = do_fuzzy_thing_with_task_name(
            $tasks,
            $old_name,
            sub {
                $dialogue->content( shift() . ' ' . $new_name );
                replan_task( $dialogue );
            }
        );
    }
    elsif ( my $complaint = check_task_name_validity($new_name, $tasks) ) {
        $reply = $complaint;
    }
    else {
        $reply = "Ok, task '$old_name' renamed '$new_name'.";
        $tasks->{$new_name} = delete $tasks->{$old_name};
        if (exists $plans->{$sender}{'working_on'}
            && $plans->{$sender}{'working_on'}{'what'} eq $old_name ) {

            $plans->{$sender}{'working_on'}{'what'} = $new_name;
        }
        $plans->{$sender}{'last_worked_on'} = $new_name;

        save_to_file( $file_of{plans}, $plans );
    }

    $dialogue->reply()->( $reply ) if $reply;
}

sub do_fuzzy_thing_with_task_name {
    my ($tasks, $task_name, $callback) = @_;

    my @candidates = guess_at_task_name($tasks, $task_name);
    if ( @candidates > 1 ) {
        return "Which $task_name do you mean? " . join ', ', @candidates;
    }
    elsif ( @candidates == 0 ) {
        return "You don't have a task named '$task_name'.";
    }
    else { # @candidates == 1
        $callback->( $candidates[0] );
    }
    return '';
}

sub guess_at_task_name {
    my ($tasks_ref, $fuzzy_name) = @_;

    my @candidates;
    for my $name ( keys %{$tasks_ref} ) {
        if ( $name =~ m[/\Q$fuzzy_name\E$] ) {
            push @candidates, $name;
        }
    }
    if ( $fuzzy_name =~ m[\.$] ) {
        $fuzzy_name =~ s[(\.)+$][];
        for my $name ( keys %{$tasks_ref} ) {
            if ( $name =~ m[/\Q$fuzzy_name\E.] ) {
                push @candidates, $name;
            }
        }
    }

    return @candidates;
}

sub start_task {
    my ($dialogue) = @_;

    my $sender = $dialogue->person();
    if (!exists $plans->{$sender}) {
        $plans->{$sender} = { 'tasks' => {} };
    }

    my $reply;

    my $task_name = trim($dialogue->content() || '');
    if (!$task_name && $plans->{$sender}{'last_worked_on'}) {
        $dialogue->content( $plans->{$sender}{'last_worked_on'} );
        start_task( $dialogue );
        return;
    }
    elsif (!$task_name) {
        $reply = 'Syntax: @start <task-name>';
    }
    elsif (!exists $plans->{$sender}{'tasks'}{$task_name}) {
        $reply = do_fuzzy_thing_with_task_name(
            $plans->{$sender}{'tasks'},
            $task_name,
            sub {
                $dialogue->content( shift );
                start_task( $dialogue );
            }
        );
    }
    else {
        $reply = "Starting task '$task_name'.";
        if (exists $plans->{$sender}{'working_on'}) {

            $reply = sprintf("Stopping task '%s'. %s",
                             $plans->{$sender}{'working_on'}{'what'},
                             $reply);
            stop_task_bureaucracy($sender);
        }
        if (rand() < .25) {
            my @addenda = ( q[Good luck!],
                            q[The clock is ticking. :)],
                            q[Buckle up!],
                            q[Giddy-up!],
                            q[Aaah, time-keeping.],
                            q[Let's show'em!] );
            $reply .= ' ' . pick(@addenda);
        }

        my $now = DateTime->now();
        $plans->{$sender}{'working_on'} = { 'what' => $task_name,
                                            'since' => $now };
        save_to_file( $file_of{plans}, $plans );
    }

    $dialogue->reply()->( $reply ) if $reply;
}

sub stop_task {
    my ($dialogue) = @_;

    my $sender = $dialogue->person();
    if (!exists $plans->{$sender}) {
        $plans->{$sender} = { 'tasks' => {} };
    }

    if (exists $plans->{$sender}{'working_on'}) {

        my $task         = $plans->{$sender}{'working_on'}{'what'};
        my $planned_time = $plans->{$sender}{'tasks'}{$task}{'planned_time'};
        my $current_task_time = current_task_spent_time($sender);
        my $elapsed_time = $plans->{$sender}{'tasks'}{$task}{'elapsed_time'}
                           + $current_task_time;

        my $percentage = 100 * $elapsed_time / $planned_time;

        my $maybe_current_time =
            $current_task_time < $elapsed_time
                 ? ' after ' . nice_time($current_task_time)
                 : '';

        $dialogue->reply()->(
            sprintf("Stopping task '%s'%s at %s out of %s (%2d%%).",
                    $task,
                    $maybe_current_time,
                    nice_time($elapsed_time),
                    nice_time($planned_time),
                    $percentage)
        );
        stop_task_bureaucracy($sender);
        save_to_file( $file_of{plans}, $plans );
    }
    else {
        $dialogue->reply()->( "There's nothing to stop." );
    }
}

sub current_task_spent_time {
    my ($planner) = @_;

    my $start_time = $plans->{$planner}{'working_on'}{'since'};
    my $now = DateTime->now();
    my $duration_since_start = $now->subtract_datetime($start_time);
    my $time_since_start = 60*$duration_since_start->hours() +
                           $duration_since_start->minutes();
    return $time_since_start;
}

sub stop_task_bureaucracy {
    my ($planner) = @_;

    my $current_task = $plans->{$planner}{'working_on'}{'what'};
    my $time_since_start = current_task_spent_time($planner);
    $plans->{$planner}{'tasks'}{$current_task}{'elapsed_time'}
        += $time_since_start;
    $plans->{$planner}{'last_worked_on'} = $current_task;
    delete $plans->{$planner}{'working_on'};
}

sub restart {
    my ($dialogue) = @_;

    my $sender = $dialogue->person();
    return if !grep { $sender eq $_ } @developers;

    system('git pull');
    exec('perl zarah.pl');
    die;
}

sub google_search {
    my ($dialogue) = @_;

    return unless $dialogue->content();

    use REST::Google::Search;
    REST::Google::Search->http_referer("http://bioclipse.net");
    my $res = REST::Google::Search->new( q => $dialogue->content() );
    if ($res->responseStatus != 200) {
        $dialogue->reply()->( 'Response status failure.' );
    }
    else {
        my @results = $res->responseData->results;
        if (@results) {
            $dialogue->reply()->( $results[0]->url );
        }
        else {
            $dialogue->reply()->( 'No hits.' );
        }
    }
}

sub bc_wiki_search {
    my ($dialogue) = @_;

    $dialogue->content( $dialogue->content() . ' site:wiki.bioclipse.net' );
    google_search($dialogue);
}

sub pelezilla_search {
    my ($dialogue) = @_;

    my $content = $dialogue->content();

    if ( !$content ) {
        my $url = 'http://bugs.bioclipse.net';
        $dialogue->reply()->( "Pelezilla is at $url" );
        return;
    }

    if ( my ($id) = $content =~ m[^\s*#?(\d+)\s*$] ) {
        my $base = $id < 3000 ? 'http://pele.farmbio.uu.se/bugzilla3/'
                              : 'http://pele.farmbio.uu.se/bugzilla36/';
        my $url = $base . "show_bug.cgi?id=$id";
        $dialogue->say()->( $url );
        return;
    }

    my $massaged_content = $dialogue->content();
    $massaged_content =~ s/ /+/g;

    my $url = 'http://pele.farmbio.uu.se/bugzilla36/buglist.cgi?'
              . 'quicksearch=' . $massaged_content;
    my $feed = XML::Feed->parse( URI->new( $url . '&ctype=atom' ));
    if ( !defined $feed ) {
        $dialogue->say()->( XML::Feed->errstr );
        return;
    }

    for my $entry ( $feed->entries < 5
                        ? $feed->entries
                        : ($feed->entries)[0..4]) {

        my $title = $entry->title;
        $title =~ s/^\[Bug /[/;
        if (length $title > 40) {
            $title = substr($title, 0, 37) . '...';
        }
        else {
            $title .= ' ' x (40-length $title);
        }
        $title .= ' ' . makeashorterlink($entry->link);
        $dialogue->say()->( $title );
    }
    if ( $feed->entries ) {
        $dialogue->say()->(
            'Entire list '
            . ($feed->entries > 5 ? q[(] . $feed->entries . q[) ] : '')
            . 'at '
            . makeashorterlink($url)
        );
    }
    else {
        $dialogue->reply()->( pick( 'Zarro boogs found.',
                                    "I couldn't find anything on '"
                                      . $dialogue->content()
                                      . "' in the database." )
                            );
    }
}

sub did_you_mean_pelezilla {
    my ($dialogue) = @_;

    $dialogue->reply()->( q[Did you mean '@pz' or '@pelezilla'?] );
}

sub trim {
    my ($string) = @_;

    $string =~ s/^\s+//;
    $string =~ s/\s+$//;

    return $string;
}

sub seen {
    my ($dialogue) = @_;

    my $person = trim($dialogue->content());
    $person =~ s/\?$//; # remove trailing question mark

    if ( $person eq $botname ) {
        $dialogue->reply()->( "I'm right here" );
        return;
    }

    if ( !exists $seen->{lc $person} ) {
        $dialogue->say()->( "I have not seen $person" );
        return;
    }

    my ($time, $chan, $quote) = @{$seen->{lc $person}};
    my $time_ago = nice_ago( DateTime->now()->subtract_datetime($time) );
    $dialogue->say()->(
        "$person was last seen $time_ago in $chan saying '$quote'"
    );
}

sub slap {
    my ($dialogue) = @_;

    my $asker = $dialogue->person();
    my $person = trim($dialogue->content());
    if ( $person eq 'me' ) {
        $person = $asker;
    }
    elsif ( $person eq 'herself' ) {
        $dialogue->reply()->("did you really think that would work?");
        $person = $asker; # revenge :)
    }

    my $possesive_form = $person
                         . (substr($person, -1, 1) eq 's' ? "'" : "'s");

    my @slap_phrases = (
        "/me slaps $person",
        "/me kicks $person in the fork",
        "/me smacks $person about with a large trout",
        "/me beats up $person",
        "/me pokes $person in the eye",
        "why on earth would I slap $person?",
        "*SMACK*, *SLAM*, take that $person!",
        "/me activates her slap-o-matic...",
        "/me orders her trained monkeys to punch $person",
        "/me smashes a lamp on $possesive_form head",
        "/me hits $person with a hammer, so he breaks into a thousand pieces",
        "/me throws some pointy lambdas at $person",
        "/me loves $person, so no slapping",
        "/me would never hurt $person!",
        "go slap $person yourself",
        "I don't perform such side effects on command!",
        "stop telling me what to do",
        "/me clobbers $person with an untyped language",
        "/me pulls $person through the Evil Mangler",
        "/me secretly deletes $possesive_form source code",
        "/me places her fist firmly on $possesive_form jaw",
        "/me locks up $person in a Monad",
        "/me submits $possesive_form email address to a dozen spam lists",
        "/me will count to five...",
        "/me jabs $person with a C pointer",
        "/me is overcome by a sudden desire to hurt $person",
        "/me karate-chops $person into two equally sized halves",
        "Come on, let's all slap $person",
        "/me pushes $person from his chair",
        "/me hits $person with an assortment of kitchen utensils",
        "/me slaps $person with a slab of concrete",
        "/me puts on her slapping gloves, and slaps $person",
        "/me decomposes $person into several parts using the Banach-Tarski "
            ."theorem and reassembles them to get two copies of $person!",
        );

    my $phrase = pick(@slap_phrases);

    if ( $person eq $botname || $person eq 'yourself' ) {
        $dialogue->say()->( pick(
            "no, I'd rather not",
            "what? you thought I'd go all ELIZA and 'slap yourself'? :)"
        ) );
        return;
    }

    if ( my ($me_phrase) = $phrase =~ m[/me\s+(.*)] ) {
        $dialogue->me()->( $me_phrase );
        # $irc->yield( ctcp => $channel => "ACTION $me_phrase" );
    }
    else {
        $dialogue->say()->( $phrase );
    }
}

sub hug {
    my ($dialogue) = @_;

    my $asker = $dialogue->person();
    my $person = trim($dialogue->content());
    if ( $person eq 'me' ) {
        $person = $asker;
    }

    my @slap_phrases = (
        "/me hugs $person",
        "/me hugs $person and blushes",
    );

    my $phrase = pick(@slap_phrases);

    if ( $person eq $botname || $person eq 'yourself' ) {
        $dialogue->say()->( pick(
            "no, I'd rather not",
            "what? you thought I'd go all ELIZA and 'hug yourself'? :)"
        ) );
        return;
    }

    if ( my ($me_phrase) = $phrase =~ m[/me\s+(.*)] ) {
        $dialogue->me()->( $me_phrase );
    }
    else {
        $dialogue->say()->( $phrase );
    }
}

sub thank {
    my ($dialogue) = @_;

    my $person = $dialogue->person();
    my $receiver = trim($dialogue->content());

    if ( $receiver ne '' && $receiver !~ m[^you\W?$] ) {
        $receiver =~ s/^(\w+)\++/$1/;
        $receiver =~ s/^(\w+) .*/$1/;

        if ($receiver eq 'me' || $receiver eq $person) {
            $dialogue->reply()->( "you can thank yourself." );
            return;
        }

        if ($receiver eq 'zarah' || $receiver eq 'you') {
            $dialogue->reply()->( "you're welcome." );
            return;
        }

        # but this won't get through in the right way on a private channel
        # hm.
        $dialogue->say()->( "$receiver: $person says thank you" );
        return;
    }

    if ( rand() < .5 && (grep { $person eq $_ } @developers) ) {
        $dialogue->reply()->( "no, YOU'RE the cute one! :)" );
    }
    else {
        $dialogue->say()->( "you're welcome, $person :)" );
    }
}

sub thanks {
    my ($dialogue) = @_;

    if ( rand() < .5 ) {
        $dialogue->reply()->( pick("you're welcome", ";)") );
    }
}

sub ping_message {
    my ($dialogue) = @_;

    my $pinger = $dialogue->person();

    if ($dialogue->content() && $dialogue->content() !~ /^me\b/) {
        return relay_message(shift, 'ping');
    }

    my $message = 'pong';
    if ($dialogue->content() =~ /^me\b/) {
        $message = 'ping';
    }

    if ( rand() < .1 ) {
        my @additions = qw<dear honey sweetie>;
        $message .= ', ' . pick(@additions);
    }
    $dialogue->reply()->($message);
}

sub ignore_pong {
    # ignore, ignore
}

sub shorten_url {
    my ($dialogue) = @_;

    my $sender = $dialogue->person();
    my $what = $dialogue->content();

    URL_SHORTENING:
    while ( $what =~ /($RE{URI}{HTTP})/g ) {

        my $url = $1;
        next URL_SHORTENING if length($url) < $url_shortening_limit;
        next URL_SHORTENING if $url =~ m[ //tinyurl ]x;
        my $tiny_url = makeashorterlink($url);
        if ( $tiny_url ) {
            $dialogue->say()->( "$sender\'s link is also $tiny_url" );
        }
    }
}

sub bug_url {
    my ($dialogue) = @_;

    #return if $dialogue->person() !~ /^CIA-\d\d/;
    return if $dialogue->channel() !~ /bioclipse|farmbio/;

    my $bug_id = $dialogue->content();
    my $base = $bug_id < 3000 ? 'http://pele.farmbio.uu.se/bugzilla3/'
                              : 'http://pele.farmbio.uu.se/bugzilla36/';
    my $url = $base . "show_bug.cgi?id=$bug_id";

    my $newurl = length($url) < $url_shortening_limit ? $url 
                                                      : makeashorterlink($url);

    $dialogue->say()->( sprintf 'bug #%04d | %s', $bug_id, $newurl );
}

sub cdk_bug_url {
    my ($dialogue) = @_;

    return if $dialogue->person() !~ /^CIA-\d\d/;
    return if $dialogue->channel() !~ /cdk|bioclipse|farmbio/;

    my $bug_id = $dialogue->content();
    my $url = 'https://sourceforge.net/tracker/?func=detail&aid='
              . $bug_id .'&group_id=20024&atid=120024';

    $dialogue->say()->( sprintf 'bug #%07d | %s', $bug_id,
                                                  makeashorterlink($url) );
}

sub gist_url {
    my ($dialogue) = @_;

    my $channel = substr($dialogue->channel(), 1);
    my @search_terms = ($channel, 'gist', split /\s+/, $dialogue->content());
    my $url = 'http://delicious.com/tag/' . join '+', @search_terms;

    $dialogue->say()->( makeashorterlink($url) );
}

sub planet_url {
    my ($dialogue) = @_;

    $dialogue->reply()->( 'http://planet.bioclipse.net' );
}

sub three_cheers {
    my ($dialogue) = @_;

    $dialogue->say()->( "hooray! hooray! hooray! :)" );
}

sub forgot_swedish {
    my ($dialogue) = @_;

    if ( $dialogue->person() =~ m/^ jonalv/x
         && $dialogue->channel() eq '#farmbio' ) {

        $dialogue->reply()->( 'C-u C-\\ swedish-postfix RET' );
    }
}

sub no_you_are_the_cute_one {
    my ($dialogue) = @_;

    if ( rand() < .1 ) {
        $dialogue->reply()->( "oh, shut up :)" );
        return;
    }

    my $attribute = $dialogue->content();

    $dialogue->reply()->(
        'no, '
        . pick(q[YOU'RE], q[YOU are]) # '
        . " the $attribute one!"
        . pick(q[], q[ :)])
    );
}

sub oh_thank_you {
    my ($dialogue) = @_;

    my @replies = (q[oh, thank you, thank you!],
                   q[you want me to leave?],
                   q[well, yeah. you're excused too.]); # '

    $dialogue->reply()->( pick(@replies) );
}

sub you_should {
    my ($dialogue) = @_;

    return unless $dialogue->content() =~ /\b$botname\b/;

    my $reply = 'Hokay. You provide the commits, I provide the "should"-ing';
    $dialogue->reply()->( $reply );
}

sub smart_girl {
    my ($dialogue) = @_;

    return unless $dialogue->content() =~ /\b$botname\b/;

    my @replies = (q[I bet you tell that to all the girls.],
                   q[If I'm so smart, how come you're shacked up with that ]
                    . q[other chick?],
                   q[Isn't it time you married me?], # '
                   q[I'm so smart I scare myself.], #'
                   q[Then why did you turn me down for that raise?],
                   q[Never mind the compliment! Take your hand off my knee!],
                   q[Not so loud, dear. I don't want my boyfriend to hear.], #'
                   q[So smart I'm looking for another job.], # '
                   q[But we _can't_ go on meeting like this!], # '
                   q[So they keep telling me.],
                   q[Flattery will get you anywhere.],
                   q[If I'm smart, why wasn't _I_ invited, too? Am I a ]
                     . q[second-class citizen?],
                   q[Then how come I'm stuck in this vat, with no body?]); # '

    my $reply = pick(@replies);
    $reply .= pick(' Over.', '');
    $dialogue->reply()->( $reply );
}

sub no_comprende {
    my ($dialogue) = @_;

    my $message = trim($dialogue->content());
    return if $message eq '--';
    return if $message eq '++';

    my @replies = (q[I did not understand that],
                   q[excuse me?],
                   q[are you making fun of me?],
                   q[that was not so easy for a little bot to understand],
                   q[eh... wha'?],                                       # '
                   q[I'm just a bot, you expect me to understand that?], # '
                   q[you've just exceeded my capabilities :/],           # '
                   q[are you talking to *me*?],                          # '
                   q[please rephrase or stop trying to be witty :)]);

    my $reply = pick(@replies);
    if ( $message =~ /^never mind\b/ ) {
        $dialogue->me()->( 'never minds' );
        return;
    }
    elsif ( $message =~ m[shut up] ) {
        $reply = pick(':)', 'no, YOU shut up!');
    }
    elsif ( $message =~ m[^consider it noted\b]i ) {
        $reply = 'hokay.';
    }
    elsif ( $message =~ /^(?:yes|no|yup|nope)\b/i ) {
        $reply = 'I see.';
    }
    elsif ( $message eq '?' ) {
        $reply = 'yes?';
    }
    elsif ( $message =~ m[hokay.?] ) {
        $reply = 'so, basically.';
    }
    elsif ( $message =~ m[^(?:just )?tell me\b] ) {
        messages( $dialogue );
        return;
    }

    $dialogue->reply()->( $reply );
}

sub help {
    my ($dialogue) = @_;

    my @cmds;
    for my $action ( @actions ) {
        my ($matcher, $code, $param) = @{$action};
        if ( ref($matcher) eq 'Regexp' ) {
            # don't list it, because it's not really a command
        }
        else { # it's a list of strings
            push @cmds, $matcher->[0];
        }
    }

    $dialogue->reply()->( 'avaliable commands are ' . join ' ', sort @cmds );
}

sub welcome {
    my ($dialogue) = @_;

    $dialogue->reply()->( 'thank you. I feel like a new person! :)' );
}

sub botsnack {
    my ($dialogue) = @_;

    $dialogue->say()->( ';)' );
}

sub tutorial {
    my ($dialogue) = @_;

    if ($dialogue->channel() ne '') {
        $dialogue->reply()->(q[sure, I'll give you the tour. Just write ] # '
                             . "'/msg $botname \@tutorial' to get started.");
        return;
    }

    my %topic_of = (
        'karma' => 'Rewarding people with operators',
        'tell'  => 'Leaving messages to people',
        'plan'  => 'Doing time management',
    );

    my $content = trim($dialogue->content() || '');
    if ($content eq '') {
        $dialogue->reply()->(sprintf 'tutorial %-8s%s', $_, $topic_of{$_})
            for sort keys %topic_of;
        $dialogue->reply()->("Write '/msg $botname \@tutorial <subject>' "
                             . 'to read a tutorial on <subject>');
        return;
    }

    if (!exists $topic_of{$content}) {
        $dialogue->reply()->("no such topic '$content'.");
        $dialogue->reply()->('available topics are '
                             . join ' ', sort keys %topic_of);
        return;
    }

    my %tutorial_of = (
        'karma' => <<"KARMA_TUTORIAL",
Any time someone writes '++' after a name in the channel, an
integer known as the 'karma' is increased by one for that
name. Writing '$botname++' would increase the karma for $botname
by one.
 
Similarly, writing '--' after a name decreases the karma for
that name. A person on IRC may not increase her own karma,
but decreasing one's own karma is fine.
 
The karma for a specific name may be checked by using the
'\@karma' command. '\@karma $botname' would check the current
karma of $botname. Writing just '\@karma' defaults to checking
the karma of the person who asked.
 
Remember that karma is the digital form of a loose social
agreement, and that rigging the karma system by cheating
in various ways is more likely to harm the community than
to give you any particular advantage.
 
End of the karma tutorial.
KARMA_TUTORIAL

        'tell'  => <<"TELL_TUTORIAL",
Sometimes you want to leave a message for another user
who is not at the keyboard. With the '\@tell' command, you
can.
 
 \@tell nicolai Your laser cannon has arrived.
 
The above command would store the message 'Your laser
cannon has arrived' to be delivered to the user 'nicolai'
the next time this person utters something in the vicinity
of $botname, saying 'nicolai: you have new messages'.
 
Arriving into a channel is not enough to trigger the
you-have-messages function; one has to actually say
something. Due to the possibility of netsplits and client
disconnections, arrival in a channel does not mean that the
person is sitting at the keyboard.
 
To read the messages left for you, use the '\@messages'
command. Various synonyms, such as '\@msg' and '\@message',
also exist for this command. If you want to read the
messages privately (which is the default suggested by
$botname), simply prepend your command with '/msg $botname'.
Otherwise, your messages will be delivered into the
channel. As a general principle, $botname usually
sends private messages only if you issue commands privately
to her.
 
There are two variants of the '\@tell' command: '\@ask', to
ask someone a question, and '\@ping', to leave an empty
message indicating that you have something to say. Apart from
the way $botname relays the messages, these commands work
exactly the same as '\@tell'.
 
End of the tell tutorial.
TELL_TUTORIAL

        'plan'  => <<"PLAN_TUTORIAL",
Using the '\@plan' command, you can keep track of the time you've
spent on various tasks in your work. An example of how the
'\@plan' command is used:
 
 \@plan website/create-login-page 2h 30m
 
After the '\@plan' command itself is the name of a new task, and
then a time specification in hours and minutes. $botname will not
let you plan tasks shorter than one minute or longer than 16 hours.
 
Planning the length of tasks ahead of time will give you
an insight into how much time is actually spent on various tasks,
as well as your own ability to estimate their length. 
 
When you start a task, issue the '\@start' command.
 
 \@start website/create-login-page
 
Usually, you can omit the name of the task after the '\@start'
command, and $botname will default to the last task you created
or worked on.
 
When you're done with a project, issue the '\@stop' command.
You don't need to write the name of the task you want to stop.
$botname will report the elapsed time of a finished task both
in absolute numbers, and as a percentage of the estimated
amount of time.
 
You can't have more than one project running at the same time --
if you issue the '\@start' command twice in succession, the first
project you started will be automatically stopped.
 
You can start and stop a task as many times as you like. In fact,
if you know that this is what you want to do, the commands
'\@pause' and '\@resume' exist as synonyms to '\@stop' and
'\@start', respectively.
 
If you change your mind after planning a task, you can remove
the task with the '\@unplan' command.
 
 \@unplan website/create-login-page
 
There's also a '\@replan' command, for when you simply want to
change the estimated time for a task.
 
 \@replan website/create-login-page 1h
 
Tasks with time already spent on them cannot be unplanned or
replanned in this way. That's the idea of the whole setup;
that you're not allowed to change your estimate once you've
begun a task.
 
The text before the slash ('/') in the task name usually
refers to a larger project of some kind. If you want, you can
skip this part when referring to tasks:
 
 \@start create-login-page
 
$botname will still find the unique project with this name for
you, or list several alternatives if the name is not unique.
 
A second shortening mechanism is if you use two or three dots
in the name.
 
 \@start create-login...
 \@start creat...
 \@start c..
 
That will also find the right task for you, as long as the
task is unique. The above two shortening mechanisms work
with every command that expects a task name.
 
Issuing just '\@plan' or '\@plan new' will give you a list
of all the tasks that you've planned but not yet started
working on. Similarly, '\@plan old' gives you all tasks
you've done some work on, '\@plan all' gives you old and
new tasks, and '\@plan last' gives you the last task you
created or worked on. If you specify something else as
an argument to the '\@plan' command:
 
 \@plan website
 
it will be assumed that you want to list all new tasks whose
name start with 'website/'. This way, you can restrict the
view of your planned tasks to a certain project. You can
also combine the new/all/old modifiers with a project name,
in any order.
 
 \@plan all website
 \@plan website all
 
If the currently active task is part of your search, both the
total time and the time the project has been active will be
shown.
 
End of the plan tutorial.
PLAN_TUTORIAL
    );

    $dialogue->reply()->($_) for split /\n/, $tutorial_of{$content};
}

sub possibly_report_new_messages {
    my ($dialogue) = @_;

    my $person = $dialogue->person();
    return if $person =~ /^CIA-\d\d$/;

    my $number_of_messages_last_time = $num_msgs->{$person} || 0;
    my $number_of_messages_now = @{$messages->{$person} or []};

    if ( $number_of_messages_now > $number_of_messages_last_time ) {
        $dialogue->reply()->(
            "You have new messages. Write '/msg $botname \@messages' to "
            . "read them."
        );
    }
}

sub irc_public {
    my ($sender, $who, $where, $what) = @_[SENDER, ARG0 .. ARG2];
    my $nick = ( split /!/, $who )[0];
    my $channel = $where->[0];

    my $now = DateTime->now();
    $seen->{lc $nick} = [ $now, $channel, $what ];
    save_to_file( $file_of{seen}, $seen );

    add_to_log( $what, $who, $channel );

    if ( exists $last_thing_said_on{$channel}
         && $last_thing_said_on{$channel} eq $what ) {

        if ( ++$repeat_count_on{$channel} == 3 ) {
            utter( $last_thing_said_on{$channel}, $channel, $irc );
        }
    }
    else {
        $repeat_count_on{$channel} = 1;
        $last_thing_said_on{$channel} = $what;
    }

    my $dialogue = Dialogue->new(
            'person'  => $nick,
            'channel' => $channel,

            'reply'   => sub { reply_to( $nick, shift, $channel, $irc ) },
            'say'     => sub { utter( shift, $channel, $irc ) },
            'me'      => sub { $irc->yield( ctcp => $channel
                               => 'ACTION ' . shift ) },
    );

    my $action_matched = '';
    ACTION:
    for my $action ( @actions ) {
        my ($matcher, $code, $param) = @{$action};
        if ( ref($matcher) eq 'Regexp' ) {
            if ( my ($matched_text) = $what =~ /$matcher/ ) {
                if ( !defined $matched_text) {
                    $matched_text = $what;
                }

                $dialogue->content($matched_text || '');
                $code->($dialogue);
                if ( defined $param && $param =~ /final/ ) {
                    $action_matched++;
                    last ACTION;
                }
            }
        }
        else { # it's a list of strings
            for my $command ( @$matcher ) {

                my $matched_text;
                if ( defined $param
                     && $param =~ /bare/
                     && (($matched_text) = $what =~ /^$command\b(?: (.*))?/) ) {

                    $dialogue->content($matched_text || '');
                    $code->($dialogue);

                    $action_matched++;
                    last ACTION;
                }
                elsif ( ($matched_text)
                      = $what =~ /^$botname(?:[:,])? $command\b(?: (.*))?/ ) {

                    $dialogue->content($matched_text || '');
                    $code->($dialogue);
                    
                    $action_matched++;
                    last ACTION;
                }
                elsif ( ($matched_text) = $what =~ /^\@$command\b(?: (.*))?/ ) {

                    $dialogue->content($matched_text || '');
                    $code->($dialogue);
                    
                    $action_matched++;
                    last ACTION;
                }
            }
        }
    }

    possibly_report_new_messages( $dialogue );
    $num_msgs->{$nick} = @{$messages->{$nick} or []};

    return;
}

sub irc_join {
    my ($sender, $who, $channel) = @_[SENDER, ARG0, ARG1];
    my $nick = ( split /!/, $who )[0];

    if ( $nick =~ /^(?:meklund|mek)/ ) {
        my $greeting = rand() < .5 ? 'dober dan!' : 'ni hao!';
        reply_to($nick, $greeting, $channel, $irc);
    }

    if ( $channel =~ /farmbio|november-wiki/ && exists $trusts->{$nick} ) {
        utter("op $channel $nick", 'ChanServ', $irc);
    }
}

sub irc_msg {
    my ($sender, $who, $receivers, $what) = @_[SENDER, ARG0 .. ARG2];
    my $nick = ( split /!/, $who )[0];

    my $dialogue = Dialogue->new(
            'person'  => $nick,
            'channel' => '',

            'reply'   => sub { utter( shift, $nick, $irc ) },
            'say'     => sub { utter( shift, $nick, $irc ) },
            'me'      => sub { $irc->yield( ctcp => $nick
                               => 'ACTION ' . shift ) },
    );

    my $action_matched = '';
    ACTION:
    for my $action ( @actions ) {
        my ($matcher, $code, $param) = @{$action};
        if ( ref($matcher) eq 'Regexp'
             && defined $param && $param eq 'final' ) {

            if ( my ($matched_text) = $what =~ /$matcher/ ) {

                if ( !defined $matched_text ) {
                    $matched_text = $what;
                }

                $dialogue->content($matched_text || '');
                $code->($dialogue);

                $action_matched++;
                last ACTION;
            }
        }
        elsif ( ref($matcher) eq 'Regexp' ) {
            # For now, let's not listen to other matches at all on the private
            # channel. Might be revised later. (For example, tinyURLs would be
            # a nice feature.)
        }
        else { # it's a list of strings
            for my $command ( @$matcher ) {

                my $matched_text;
                if ( ($matched_text)
                      = $what =~ /^(?:$botname[:,]?\s*)?\@?$command\b(?: (.*))?/
                   ) {

                    $dialogue->content($matched_text || '');
                    $code->($dialogue);

                    $action_matched++;
                    last ACTION;
                }
            }
        }
    }

    if (!$action_matched) {
        $dialogue->say()->("Sorry, I did not understand that.");
    }
}

# We registered for all events, this will produce some debug info.
sub _default {
    my ($event, $args) = @_[ARG0 .. $#_];

    return if $event eq 'irc_ping' || $event =~ /^irc_\d/;

    my @output = ( "$event: " );

    for my $arg (@$args) {
        if ( ref $arg eq 'ARRAY' ) {
            push( @output, '[' . join(' ,', @$arg ) . ']' );
        }
        else {
            push ( @output, "'$arg'" );
        }
    }
    print join ' ', @output, "\n";

    if ( $event eq 'irc_disconnected' ) {

      if ( $want_to_restart ) {
          utter( "eeeeep!", '#farmbio', $irc );
          restart('masak');
      }

      print "Trying again...\n";

      my $irc = POE::Component::IRC->spawn( 
          nick => $botname,
          ircname => $ircname,
          server => $server,
      ) or die "Oh noooo! $!";

      $irc->plugin_add( 'NickServID', POE::Component::IRC::Plugin::NickServID->new(
          Password => 'ettlosenord'
      ));

      POE::Session->create(
          package_states => [
              main => [ qw(_default _start irc_001 irc_public) ],
          ],
          heap => { irc => $irc },
      );

      $poe_kernel->run();
    }

    return 0;
}
