package Test::Stream::Spec;
use strict;
use warnings;

my @ACCESSORS;
BEGIN {
    @ACCESSORS = qw{
        subtests multipliers

        pre_all  pre_mult  pre_test
        post_all post_mult post_test
    };
}

use Test::Stream::HashBase accessors => [@ACCESSORS, qw/code name context specs todo skip block root/];
use Test::Stream::Util qw/try/;
use Test::Stream::Subtest qw/subtest/;
use Test::Stream::Meta qw/init_tester/;
use Test::Stream::Block;
use Test::Stream::ForceExit;
use Test::Stream qw/cull/;

use Test::Stream::Carp qw/croak confess/;
use Scalar::Util qw/weaken/;

use Test::Stream::Exporter qw/exports/;
exports qw/spec build_spec default_runner follow root_spec/;
Test::Stream::Exporter->cleanup;

my (%SPECS, @SPEC, %FOLLOWS);
sub follow {
    my $hub = Test::Stream->shared;
    return if $FOLLOWS{$hub}++;
    $hub->follow_up(sub {
        for my $pkg (keys %SPECS) {
            my $root = $SPECS{$pkg};
            my $meta = init_tester($pkg);
            my $key = __PACKAGE__;

            $root->run(
                runner => $meta->stash->{$key}->{runner} || undef,
                args   => $meta->stash->{$key}->{args}   || undef,
            );
        }
    });
}

sub root_spec {
    my ($pkg, $vivify) = @_;

    if ($vivify && !$SPECS{$pkg}) {
        my $ctx = Test::Stream::Context::context(1);
        $SPECS{$pkg} = __PACKAGE__->new(context => $ctx->snapshot, name => $pkg, root => 1);
    }

    return $SPECS{$pkg} || undef;
}

sub spec {
    my ($pkg) = @_;

    return $SPEC[-1] if @SPEC;
    return undef unless $pkg;

    root_spec($pkg, 1);
}

sub build_spec {
    my ($spec, $code, @args) = @_;
    push @SPEC => $spec;
    my ($ok, $err) = try { $code->(@args) };
    pop @SPEC;
    die $err unless $ok;
    $spec;
}

sub init {
    my $self = shift;

    confess "'name' is a required attribute"
        unless $self->{+NAME};

    my $ctx = Test::Stream::Context::context(1)->snapshot;

    $self->{+CONTEXT} ||= $ctx;
    $self->{+SPECS} ||= [];

    $self->{+BLOCK} ||= Test::Stream::Block->new(
        caller  => [ $ctx->call ],
        name    => $self->{+NAME},
        coderef => $self->{+CODE},
    ) if $self->{+CODE};

    for my $accessor (@ACCESSORS) {
        $self->{$accessor} ||= [];
    }
}

for my $key (@ACCESSORS) {
    my $sub = $key;
    $sub =~ s/s$//;
    my $insert = '';
    my $tail = '';
    for (1 .. 2) {
        eval <<"        EOT" || die $@;
            sub push_$sub {
                my \$self = shift;
                my \$name = shift;
                my \$code = pop;
                my \$params = shift;

                my \$ctx = Test::Stream::Context::context()->snapshot;

                my \$block = Test::Stream::Block->new(
                    coderef => \$code,
                    name    => \$name,
                    caller  => [\$ctx->call],
                );

                my \$it = {
                    context => \$ctx,
                    \$params ? (\%\$params) : (),
                    name  => \$name,
                    block => \$block,
                    code  => \$code,
                    type  => '$sub',
                    $insert
                };

                for my \$r (qw/code name type context/) {
                    confess "'\$r' is a required attribute"
                        unless \$it->{\$r};
                }

                $tail
                push \@{\$self->{'$key'}} => \$it;
            }

            1;
        EOT
        last unless $key =~ m/^pre_(\S+)/;
        $sub = "wrap_$1";
        $insert = 'wrap => 1,';
        $tail = qq|push \@{\$self->{'post_$1'}} => { pop => 1 };|;
    }
}

sub push_spec {
    my $self = shift;
    push @{$self->{+SPECS}} => @_;
}

sub _encapsulate {
    my ($inner, $params, $pre, $post) = @_;

    # These are closed over for use in iteration. We need this because things
    # may nest because we allow wrap_*.
    my $pre_i = 0;
    my $post_i = 0;
    my $ended = 0;

    # This is the very end, essentially the final subtest we are trying to run.
    my $end = sub {
        my @args = @_;

        # Get the context, but alter it so it points at the place where the
        # block was defined.
        my $ctx = Test::Stream::Context::context();
        $ctx->set_frame($params->{context}->frame);
        $ctx->set_detail($params->{block}->detail) if $params->{block};
        $ctx->set_detail($params->{context}->package . " (root spec)") if $params->{root};
        try { subtest($params->{name}, $inner, @args) };
    };

    # This is a recursive anonymous sub, the variable is declared here so we
    # can reference it inside. This variable gets weakened later to avoid a
    # memory leak.
    my $iter;
    $iter = sub {
        my $ctx = Test::Stream::Context::context();

        # First loop through all the pre-blocks, if they are wrap_* we recurse
        # into them.
        # The iterator is closed over so we continue where we left off.
        my @args = @_;
        while ($pre_i < @$pre) {
            my $p = $pre->[$pre_i++];
            my $pctx = $ctx->snapshot;
            $pctx->set_frame($p->{context}->frame);

            if ($p->{wrap}) {
                $pctx->note("Entering: $p->{name}");
                my ($ok, $err) = try {$p->{code}->(sub {$iter->(@args)}, @args)};
                $pctx->bail($err) unless $ok;
                $pctx->note("Leaving: $p->{name}");
                last;
            }

            $pctx->note("Running: $p->{name}");
            my ($ok, $err) = try { $p->{code}->(@args) };
            $ctx->bail($err) unless $ok;
        }

        # Now we run the final set of stuff. Use ended so that calls already on
        # the stack do not do it again.
        $end->(@args) unless $ended++;

        # Now run the post-blocks. There will be fake entries with the 'pop'
        # key set that tell us to return from a wrap_* block.
        # The iterator is closed over so we continue where we left off.
        while ($post_i < @$post) {
            my $p = $post->[$post_i++];
            return if $p->{pop};

            my $pctx = $ctx->snapshot;
            $pctx->set_frame($p->{context}->frame);

            $pctx->note("Running: $p->{name}");
            my ($ok, $err) = try { $p->{code}->(@args) };
            $pctx->bail($err) unless $ok;
        }
    };

    # Make a copy before weakening the sub so that we can use it.
    my $iter_ref = $iter;
    weaken($iter);

    my $out = {( %$params, code => sub {$pre_i = 0; $post_i = 0; $ended = 0; $iter_ref->(@_)} )};
    return $out;
}

sub _compile {
    my $self = shift;
    my ($runner, $pre, $post) = @_;
    $pre  ||= [];
    $post ||= [];
    push @$pre  => @{$self->{+PRE_TEST}};
    push @$post => @{$self->{+POST_TEST}};

    my @subtests = map { _encapsulate($_->{code}, $_, $pre, $post) } @{$self->{+SUBTESTS}};
    push @subtests => $_->_compile($runner, [@$pre], [@$post]) for @{$self->{+SPECS}};

    my @run;
    if (@{$self->{+MULTIPLIERS}}) {
        @run = map {
            my $mul = $_;
            _encapsulate(
                sub {
                    $mul->{code}->(@_);
                    $runner->($_, @_) for @subtests;
                },
                $mul,
                $self->{+PRE_MULT},
                $self->{+POST_MULT},
            );
        } @{$self->{+MULTIPLIERS}};
    }
    else {
        @run = @subtests;
    }

    return _encapsulate(
        sub { $runner->($_, @_) for @run },
        $self,
        $self->{+PRE_ALL},
        $self->{+POST_ALL},
    );
}

sub run {
    my $self = shift;
    my %args = @_;

    my $ctx = Test::Stream::Context::context();

    my $runner = $args{runner} || \&default_runner;
    my $args   = $args{args};

    my $unit = $self->_compile($runner);
    $runner->($unit, $args ? @$args : ());
}

sub default_runner {
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
    if ($unit->{iso} && $unit->{type} eq 'subtest') {
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


1;

__END__


=pod

=head1 NAME

Test::Stream::Spec - A SPEC builder library for intercompatible SPEC tools.

=head1 SYNOPSIS

    package My::SpecTool;

    use Test::Stream qw/context/;
    use Test::Stream::Spec qw/spec build_spec root_spec follow/;
    use Test::Stream::Exporter;
    default_exports qw/workflow tests before_each/;
    Test::Stream::Exporter->cleanup;

    sub after_import {
        my $class = shift;
        my ($importer) = @_;

        root_spec($importer, 1);

        follow();
    }

    sub workflow {
        my ($name, $code) = @_;

        my $caller = caller;
        my $parent = spec($caller);

        my $ctx = context();
        my $spec = $CLASS->new(context => $ctx->snapshot, name => $name, code => $code);
        $ctx = undef;

        build_spec($spec => $code);

        $parent->push_spec($spec);
    }

    sub tests {
        my ($name, $code) = @_;
        my $ctx = context();
        my $caller = caller;
        my $spec = spec($caller);
        $spec->push_subtest(@_);
    }

    sub before_each {
        my ($name, $code) = @_;
        my $ctx = context();
        my $caller = caller;
        my $spec = spec($caller);
        $spec->push_pre_test(@_);
    }

=head1 DESCRIPTION

Ruby has RSPEC. In perl we have several implementations, none of which work
well together. This is an attempt to do what Test-Builder did with basic
testing libraries, let them play nice! If you write SPEC based tools and use
this library they will play nicely with any other tools that use this library.

=head1 EXPORTS

=over 4

=item $spec = spec()

=item $spec = spec($pkg)

This is the behavior needed by most tools.

Returns the curently building spec object if there is one, ignoring the C<$pkg>
arg in such cases. If no spec is building, it will return the root spec for the
specified package, generating it if necessary. If there is no building spec,
and no package is provided, it return undef.

=item $spec = root_spec($pkg, $vivify)

This will return the root spec for the specified package. If there is no root
spec for the package it will return undef, unless C<$vivify> is true, in which
case it generates one and returns it.

=item follow()

Running this will install the follow-up handlers into the current shared
L<Test::Stream::Hub>. This is safe to call multiple times, it will only install
the follow-up behavior once per hub.

Most SPEC tools will want to call this on import, but some modules may not want
to, so it is NOT done automatically.

=item build_spec($spec, $code, @args)

This will push the C<$spec> object to the top of the build list, then it will
execute your C<$code> with the specified C<@args>. Once C<$code> returns,
C<$spec> will be popped from the build list.

=item default_runner($unit, @args)

This is the default runner used to run spec objects.

=back

=head1 INSTANCE METHODS

=over 4

=item $spec->run()

=item $spec->run( args => [], runner => sub {...} )

This will compile and run the spec. The args will be passed to every block if
specified. If no runner is specified the default will be used.

=head2 PUSH METHODS

With exception of C<push_spec()> which expects a fully formed
L<Test::Stream::Spec> object, these accept the same 2 or 3 arguments. The first
argument must always be the name of the block, the last must be a codeblock. If
there are 3 arguments, the middle should be a hashref with paremeters for the
block.

=item $spec->push_spec($spec)

=item $spec->push_multiplier( $name, sub { ... } )

=item $spec->push_multiplier( $name, \%params, sub { ... } )

=item $spec->push_post_all( $name, sub { ... } )

=item $spec->push_post_all( $name, \%params, sub { ... } )

=item $spec->push_post_mult( $name, sub { ... } )

=item $spec->push_post_mult( $name, \%params, sub { ... } )

=item $spec->push_post_test( $name, sub { ... } )

=item $spec->push_post_test( $name, \%params, sub { ... } )

=item $spec->push_pre_all( $name, sub { ... } )

=item $spec->push_pre_all( $name, \%params, sub { ... } )

=item $spec->push_pre_mult( $name, sub { ... } )

=item $spec->push_pre_mult( $name, \%params, sub { ... } )

=item $spec->push_pre_test( $name, sub { ... } )

=item $spec->push_pre_test( $name, \%params, sub { ... } )

=item $spec->push_subtest( $name, sub { ... } )

=item $spec->push_subtest( $name, \%params, sub { ... } )

=back

=head1 RUNNERS

=head2 DEFAULT RUNNER

=head2 CONCURRENCY RUNNER

=head2 CUSTOM RUNNERS

=head1 BLOCK TYPES

=head2 SUBTEST BLOCKS

=head2 MULTIPLIER BLOCKS

=head2 MODIFIER BLOCKS

=head1 SOURCE

The source code repository for Test::More can be found at
F<http://github.com/Test-More/test-more/>.

=head1 MAINTAINER

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2015 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://www.perl.com/perl/misc/Artistic.html>

=back

=cut
