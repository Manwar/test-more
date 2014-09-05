package Test::Builder;

use 5.008001;
use strict;
use warnings;

our $VERSION = '1.301001_041';
$VERSION = eval $VERSION;    ## no critic (BuiltinFunctions::ProhibitStringyEval)

use Test::More::Tools;

use Test::Stream;
use Test::Stream::Toolset;
use Test::Stream::Context;
use Test::Stream::Threads;

use Test::Stream::Util qw/try protect unoverload_str is_regex/;
use Scalar::Util qw/blessed reftype/;

BEGIN {
    Test::Stream->shared->set_use_legacy(1);
}

# The mostly-singleton, and other package vars.
our $Test  = Test::Builder->new;
our $Level = 1;

sub ctx {
    my $self = shift || die "No self in context";
    my $ctx = Test::Stream::Context::context($Level);
    $ctx->set_stream($self->{stream}) if $self->{stream};
    if (defined $self->{Todo}) {
        $ctx->set_in_todo(1);
        $ctx->set_todo($self->{Todo});
    }
    return $ctx;
}

####################
# {{{ Constructors #
####################

sub new {
    my $class  = shift;
    my %params = @_;
    $Test ||= $class->create(shared_stream => 1);

    return $Test;
}

sub create {
    my $class  = shift;
    my %params = @_;

    my $self = bless {}, $class;
    $self->reset(%params);

    return $self;
}

# Copy an object, currently a shallow.
# This does *not* bless the destination.  This keeps the destructor from
# firing when we're just storing a copy of the object to restore later.
sub _copy {
    my ($src, $dest) = @_;
    %$dest = %$src;
    return;
}

####################
# }}} Constructors #
####################

#############################
# {{{ Children and subtests #
#############################

sub subtest {
    my $self = shift;
    my($name, $subtests, @args) = @_;

    my $ctx = $self->ctx();

    $ctx->throw("subtest()'s second argument must be a code ref")
        unless $subtests && 'CODE' eq reftype($subtests);

    local $Level = 1;
    my $ok = $ctx->nest($subtests, @args);
    $ctx->ok($ok, $name);

    return $ok;
}

#############################
# }}} Children and subtests #
#############################

#####################################
# {{{ stuff for TODO status #
#####################################

sub find_TODO {
    my ($self, $pack, $set, $new_value) = @_;

    if (my $ctx = Test::Stream::Context->peek) {
        $pack = $ctx->package;
        my $old = $ctx->todo;
        $ctx->set_todo($new_value) if $set;
        return $old;
    }

    $pack = $self->exported_to || return;

    no strict 'refs';    ## no critic
    no warnings 'once';
    my $old_value = ${$pack . '::TODO'};
    $set and ${$pack . '::TODO'} = $new_value;
    return $old_value;
}

sub todo {
    my ($self, $pack) = @_;

    return $self->{Todo} if defined $self->{Todo};

    my $todo = $self->find_TODO($pack);
    return $todo if defined $todo;

    return '';
}

sub in_todo {
    my $self = shift;

    return (defined $self->{Todo} || $self->find_TODO) ? 1 : 0;
}

sub todo_start {
    my $self = shift;
    my $message = @_ ? shift : '';

    $self->{Start_Todo}++;
    if ($self->in_todo) {
        push @{$self->{Todo_Stack}} => $self->todo;
    }
    $self->{Todo} = $message;

    return;
}

sub todo_end {
    my $self = shift;

    if (!$self->{Start_Todo}) {
        $self->ctx()->throw('todo_end() called without todo_start()');
    }

    $self->{Start_Todo}--;

    if ($self->{Start_Todo} && @{$self->{Todo_Stack}}) {
        $self->{Todo} = pop @{$self->{Todo_Stack}};
    }
    else {
        delete $self->{Todo};
    }

    return;
}

#####################################
# }}} Finding Testers and Providers #
#####################################

################
# {{{ Planning #
################

my %PLAN_CMDS = (
    no_plan  => 'no_plan',
    skip_all => 'skip_all',
    tests    => '_plan_tests',
);

sub plan {
    my ($self, $cmd, $arg) = @_;
    return unless $cmd;

    if (my $method = $PLAN_CMDS{$cmd}) {
        $self->$method($arg);
    }
    else {
        my @args = grep { defined } ($cmd, $arg);
        $self->ctx->throw("plan() doesn't understand @args");
    }

    return 1;
}

sub skip_all {
    my ($self, $reason) = @_;

    $self->{Skip_All} = $self->parent ? $reason : 1;

    die bless {} => 'Test::Builder::Exception' if $self->parent;
    $self->ctx()->plan(0, 'SKIP', $reason);
}

sub no_plan {
    my ($self, @args) = @_;

    $self->ctx()->alert("no_plan takes no arguments") if @args;
    $self->ctx()->plan(0, 'NO_PLAN');

    return 1;
}

sub _plan_tests {
    my ($self, $arg) = @_;

    if ($arg) {
        $self->ctx()->throw("Number of tests must be a positive integer.  You gave it '$arg'")
            unless $arg =~ /^\+?\d+$/;

        $self->ctx()->plan($arg);
    }
    elsif (!defined $arg) {
        $self->ctx()->throw("Got an undefined number of tests");
    }
    else {
        $self->ctx()->throw("You said to run 0 tests");
    }

    return;
}

sub done_testing {
    my ($self, $num_tests) = @_;
    $self->ctx()->done_testing($num_tests);
}

################
# }}} Planning #
################

#############################
# {{{ Base Event Producers #
#############################

sub ok {
    my $self = shift;
    my($test, $name) = @_;
    $self->ctx()->ok($test, $name);
    return $test ? 1 : 0;
}

sub BAIL_OUT {
    my( $self, $reason ) = @_;

    if ($self->parent) {
        $self->{Bailed_Out_Reason} = $reason;
        $self->no_ending(1);
        die bless {} => 'Test::Builder::Exception';
    }

    $self->ctx()->bail($reason);
}

sub skip {
    my( $self, $why ) = @_;
    $why ||= '';
    unoverload_str( \$why );

    my $ctx = $self->ctx();
    $ctx->set_skip($why);
    $ctx->ok(1);
    $ctx->set_skip(undef);
}

sub todo_skip {
    my( $self, $why ) = @_;
    $why ||= '';
    unoverload_str( \$why );

    my $ctx = $self->ctx();
    $ctx->set_skip($why);
    $ctx->set_todo($why);
    $ctx->ok(1);
    $ctx->set_skip(undef);
    $ctx->set_todo(undef);
}

sub diag {
    my $self = shift;
    my $msg = join '', map { defined($_) ? $_ : 'undef' } @_;
    $self->ctx->diag($msg);
    return;
}

sub note {
    my $self = shift;
    my $msg = join '', map { defined($_) ? $_ : 'undef' } @_;
    $self->ctx->note($msg);
}

#############################
# }}} Base Event Producers #
#############################

#######################
# {{{ Public helpers #
#######################

sub explain {
    my $self = shift;

    return map {
        ref $_
          ? do {
            protect { require Data::Dumper };
            my $dumper = Data::Dumper->new( [$_] );
            $dumper->Indent(1)->Terse(1);
            $dumper->Sortkeys(1) if $dumper->can("Sortkeys");
            $dumper->Dump;
          }
          : $_
    } @_;
}

sub carp {
    my $self = shift;
    $self->ctx->alert(join '' => @_);
}

sub croak {
    my $self = shift;
    $self->ctx->throw(join '' => @_);
}

sub has_plan {
    my $self = shift;

    my $plan = $self->ctx->stream->plan || return undef;
    return 'no_plan' if $plan->directive && $plan->directive eq 'NO_PLAN';
    return $plan->max;
}

sub reset {
    my $self = shift;
    my %params = @_;

    $self->{stream} = Test::Stream->new()
        unless $params{shared_stream};

    # We leave this a global because it has to be localized and localizing
    # hash keys is just asking for pain.  Also, it was documented.
    $Level = 1;

    $self->{Name} = $0;

    $self->{Original_Pid} = $$;
    $self->{Child_Name}   = undef;

    $self->{Exported_To} = undef;

    $self->{Todo}               = undef;
    $self->{Todo_Stack}         = [];
    $self->{Start_Todo}         = 0;
    $self->{Opened_Testhandles} = 0;

    return;
}

#######################
# }}} Public helpers #
#######################

#################################
# {{{ Advanced Event Producers #
#################################

sub cmp_ok {
    my( $self, $got, $type, $expect, $name ) = @_;
    my $ctx = $self->ctx;
    my ($ok, @diag) = tmt->cmp_check($got, $type, $expect);
    $ctx->ok($ok, $name, \@diag);
    return $ok;
}

sub is_eq {
    my( $self, $got, $expect, $name ) = @_;
    my $ctx = $self->ctx;
    my ($ok, @diag) = tmt->is_eq($got, $expect);
    $ctx->ok($ok, $name, \@diag);
    return $ok;
}

sub is_num {
    my( $self, $got, $expect, $name ) = @_;
    my $ctx = $self->ctx;
    my ($ok, @diag) = tmt->is_num($got, $expect);
    $ctx->ok($ok, $name, \@diag);
    return $ok;
}

sub isnt_eq {
    my( $self, $got, $dont_expect, $name ) = @_;
    my $ctx = $self->ctx;
    my ($ok, @diag) = tmt->isnt_eq($got, $dont_expect);
    $ctx->ok($ok, $name, \@diag);
    return $ok;
}

sub isnt_num {
    my( $self, $got, $dont_expect, $name ) = @_;
    my $ctx = $self->ctx;
    my ($ok, @diag) = tmt->isnt_num($got, $dont_expect);
    $ctx->ok($ok, $name, \@diag);
    return $ok;
}

sub like {
    my( $self, $thing, $regex, $name ) = @_;
    my $ctx = $self->ctx;
    my ($ok, @diag) = tmt->regex_check($thing, $regex, '=~');
    $ctx->ok($ok, $name, \@diag);
    return $ok;
}

sub unlike {
    my( $self, $thing, $regex, $name ) = @_;
    my $ctx = $self->ctx;
    my ($ok, @diag) = tmt->regex_check($thing, $regex, '!~');
    $ctx->ok($ok, $name, \@diag);
    return $ok;
}

#################################
# }}} Advanced Event Producers #
#################################

################################################
# {{{ Misc #
################################################

#output failure_output todo_output

sub _new_fh {
    my $self = shift;
    my($file_or_fh) = shift;

    return $file_or_fh if $self->is_fh($file_or_fh);

    my $fh;
    if( ref $file_or_fh eq 'SCALAR' ) {
        open $fh, ">>", $file_or_fh
          or croak("Can't open scalar ref $file_or_fh: $!");
    }
    else {
        open $fh, ">", $file_or_fh
          or croak("Can't open test output log $file_or_fh: $!");
        Test::Stream::IOSets_autoflush($fh);
    }

    return $fh;
}

sub output {
    my $self = shift;
    my $handles = $self->ctx->stream->io_sets->init_encoding('legacy');
    $handles->[0] = $self->_new_fh(@_) if @_;
    return $handles->[0];
}

sub failure_output {
    my $self = shift;
    my $handles = $self->ctx->stream->io_sets->init_encoding('legacy');
    $handles->[1] = $self->_new_fh(@_) if @_;
    return $handles->[1];
}

sub todo_output {
    my $self = shift;
    my $handles = $self->ctx->stream->io_sets->init_encoding('legacy');
    $handles->[2] = $self->_new_fh(@_) if @_;
    return $handles->[2] || $handles->[0];
}

sub reset_outputs {
    my $self = shift;
    my $ctx = $self->ctx;
    $ctx->stream->io_sets->reset_legacy;
}

sub use_numbers {
    my $self = shift;
    my $ctx = $self->ctx;
    $ctx->stream->set_use_numbers(@_) if @_;
    $ctx->stream->use_numbers;
}

sub no_ending {
    my $self = shift;
    my $ctx = $self->ctx;
    $ctx->stream->set_no_ending(@_) if @_;
    $ctx->stream->no_ending;
}

sub no_header {
    my $self = shift;
    my $ctx = $self->ctx;
    $ctx->stream->set_no_header(@_) if @_;
    $ctx->stream->no_header;
}

sub no_diag {
    my $self = shift;
    my $ctx = $self->ctx;
    $ctx->stream->set_no_diag(@_) if @_;
    $ctx->stream->no_diag;
}

sub exported_to {
    my($self, $pack) = @_;
    $self->{Exported_To} = $pack if defined $pack;
    return $self->{Exported_To};
}

sub is_fh {
    my $self     = shift;
    my $maybe_fh = shift;
    return 0 unless defined $maybe_fh;

    return 1 if ref $maybe_fh  eq 'GLOB';    # its a glob ref
    return 1 if ref \$maybe_fh eq 'GLOB';    # its a glob

    my $out;
    protect {
        $out = eval { $maybe_fh->isa("IO::Handle") }
            || eval { tied($maybe_fh)->can('TIEHANDLE') };
    };

    return $out;
}

sub BAILOUT { goto &BAIL_OUT }

sub expected_tests {
    my $self = shift;

    my $ctx = $self->ctx;
    $ctx->plan(@_) if @_;

    my $plan = $ctx->plan || return 0;
    return $plan->max || 0;
}

sub caller {    ## no critic (Subroutines::ProhibitBuiltinHomonyms)
    my $self = shift;

    my $ctx = $self->ctx;

    return wantarray ? $ctx->call : $ctx->package;
}

sub level {
    my( $self, $level ) = @_;
    $Level = $level if defined $level;
    return $Level;
}

sub maybe_regex {
    my ($self, $regex) = @_;
    return is_regex($regex);
}

sub is_passing {
    my $self = shift;
    my $ctx = $self->ctx;
    $ctx->stream->is_passing(@_);
}

sub current_test {
    my $self = shift;

    my $ctx = $self->ctx;

    if (@_) {
        my ($num) = @_;
        my $state = $ctx->stream->state->[-1];
        my $start = $state->[STATE_COUNT];
        $state->[STATE_COUNT] = $num;
        if ($start > $num) {
            $state->[STATE_LEGACY] = [$state->[STATE_LEGACY]->[0 .. $num]];
        }
        elsif ($start < $num) {
            my $nctx = $ctx->snapshot;
            $nctx->set_todo('incrementing test number');
            $nctx->set_in_todo(1);
            my $ok = Test::Stream::Event::Ok->new(
                $ctx,
                [CORE::caller()],
                undef,
                'FAKE',
                undef,
                1,
            );
            push @{$state->[STATE_LEGACY]} => $ok for $num - $start;
        }
    }

    $ctx->stream->count;
}

sub details {
    my $self = shift;
    my $ctx = $self->ctx;
    my $state = $ctx->stream->state;
    return unless $state->[STATE_LEGACY];
    return map {
        my $result = &share( {} );

        $result->{ok} = $_->bool;
        $result->{actual_ok} = $_->real_bool;
        $result->{name} = $_->name || '';

        if($_->skip && ($_->in_todo || $_->todo)) {
            $result->{type} = 'todo_skip',
            $result->{reason} = $_->skip || $_->todo;
        }
        elsif($_->in_todo || $_->todo) {
            $result->{reason} = $_->todo;
            $result->{type}   = 'todo';
        }
        elsif($_->skip) {
            $result->{reason} = $_->skip;
            $result->{type}   = 'skip';
        }
        else {
            $result->{reason} = '';
            $result->{type}   = '';
        }

        if ($result->{reason} eq 'incrementing test number') {
            $result->{type} = 'unknown';
        }

        $result;
    } @{$state->[STATE_LEGACY]};
}

sub summary {
    my $self = shift;
    my $ctx = $self->ctx;
    my $state = $ctx->stream->state;
    return unless $state->[STATE_LEGACY];
    return map { $_->bool ? 1 : 0 } @{$state->[STATE_LEGACY]};
}

###################################
# }}} Misc #
###################################

####################
# {{{ TB1.5 stuff  #
####################

# This is just a list of method Test::Builder current does not have that Test::Builder 1.5 does.
my %TB15_METHODS = map { $_ => 1 } qw{
    _file_and_line _join_message _make_default _my_exit _reset_todo_state
    _result_to_hash _results _todo_state formatter history in_subtest in_test
    no_change_exit_code post_event post_result set_formatter set_plan test_end
    test_exit_code test_start test_state
};

our $AUTOLOAD;

sub AUTOLOAD {
    $AUTOLOAD =~ m/^(.*)::([^:]+)$/;
    my ($package, $sub) = ($1, $2);

    my @caller = CORE::caller();
    my $msg    = qq{Can't locate object method "$sub" via package "$package" at $caller[1] line $caller[2]\n};

    $msg .= <<"    EOT" if $TB15_METHODS{$sub};

    *************************************************************************
    '$sub' is a Test::Builder 1.5 method. Test::Builder 1.5 is a dead branch.
    You need to update your code so that it no longer treats Test::Builders
    over a specific version number as anything special.

    See: http://blogs.perl.org/users/chad_exodist_granum/2014/03/testmore---new-maintainer-also-stop-version-checking.html
    *************************************************************************
    EOT

    die $msg;
}

####################
# }}} TB1.5 stuff  #
####################

1;
