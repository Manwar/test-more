package Test::Stream::Spec::CoRunner;
use strict;
use warnings;

use POSIX ":sys_wait_h";
use IO::Socket::UNIX;
use File::Temp qw/tempfile/;
use Test::Stream::Carp qw/croak/;
use Test::Stream::HashBase(
    accessors => [qw/socket/],
);

sub runner {
    my $class = shift;
    my ($limit) = @_;
    $limit = 3 unless $limit && $limit >= 3;

    my $iso_max = $limit / 3;
    my $work_max = $limit - $iso_max;
    my @max = ($iso_max, $work_max);
    my @use = (0, 0);

    my ($fh, $hostpath) = tempfile();

    my $server = IO::Socket::UNIX->new(
        Type => SOCK_STREAM(),
        Listen => $limit,
        Local => $fh,
    ) || croak "Could not create socket!";

    my $self = $class->new(
        socket => $hostpath,
    );

    my $listening = 0;
    return sub {
        my ($unit, @args) = @_;

        my $child;
        if ($listening++) {
            $self->work(@_);
            return;
        }
        else {
            $child = $self->spawn_worker(@_);
            $use[1]++;
        }

        while (1) {
            my $check = waitpid($child, WNOHANG);
            last if $check && ($check < 0 || $check == $child);

            my $con = $server->accept();
            my $type  = int($con->read);
            my $delta = int($con->read);

            if ($type == -1) { # Sending us the all clear
                $con->close;
                next;
            }
            elsif ($use[$type] + $delta < $max[$type]) {
                $use[$type] += $delta;
                $con->print("$delta\n");
            }
            else {
                $con->print("0\n");
            }
            $con->close;
        }
    };
};


1;

__END__

sub co_runner {
    my ($unit, @args) = @_;

    my $ctx = Test::Stream::Context::context();
    $ctx->set_frame($unit->{context}->frame);

    if ($unit->{skip}) {
        $ctx->set_skip($unit->{skip});
        $ctx->ok(1, $unit->{name});
        return;
    }

    $ctx->push_todo($unit->{todo}) if $unit->{todo};

    my ($ok, $err);
    if ($unit->{iso}) {
        $ctx->hub->use_fork();
        my $pid = fork();
        if (!defined($pid)) {
            $ok = 0;
            $err = "Failed to fork for " . $unit->{block}->detail . ".\n";
        }
        elsif($pid) {
            my $verify = waitpid($pid, 0);
            if ($verify != $pid) {
                $ok = 0;
                $err = "waitpid on $pid failed ($verify)\n";
            }
            else {
                $ok = !$?;
                $err = "Child process returned $?\n";
            }
        }
        else {
            my $fe = Test::Stream::ForceExit->new();
            ($ok, $err) = try { $unit->{code}->(@args) };
            $fe->done(1);
            exit 0 if $ok;
            print STDERR $err;
            exit 255;
        }
    }
    else {
        ($ok, $err) = try { $unit->{code}->(@args) };
    }

    $ctx->pop_todo() if $unit->{todo};

    die $err unless $ok;
};


