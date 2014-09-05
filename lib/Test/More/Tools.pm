package Test::More::Tools;
use strict;
use warnings;

use Test::Stream::Context;

use Test::Stream::Exporter;
exports qw/tmt/;
Test::Stream::Exporter->cleanup;

use Test::Stream::Util qw/try protect is_regex unoverload_str unoverload_num/;
use Scalar::Util qw/blessed/;

sub tmt() { __PACKAGE__ }

# Bad, these are not comparison operators. Should we include more?
my %CMP_OK_BL    = map { ( $_, 1 ) } ( "=", "+=", ".=", "x=", "^=", "|=", "||=", "&&=", "...");
my %NUMERIC_CMPS = map { ( $_, 1 ) } ( "<", "<=", ">", ">=", "==", "!=", "<=>" );

sub cmp_check {
    my($class, $got, $type, $expect) = @_;

    my $ctx = context();
    my $name = $ctx->subname;
    $name =~ s/^.*:://g;
    $name = 'cmp_check' if $name eq '__ANON__';
    $ctx->throw("$type is not a valid comparison operator in $name\()")
        if $CMP_OK_BL{$type};

    my ($p, $file, $line) = $ctx->call;

    my $test;
    my ($success, $error) = try {
        # This is so that warnings come out at the caller's level
        ## no critic (BuiltinFunctions::ProhibitStringyEval)
        eval qq[
#line $line "$file"
\$test = \$got $type \$expect;
1;
        ] || die $@;
    };

    my @diag;
    push @diag => <<"    END" unless $success;
An error occurred while using $type:
------------------------------------
$error
------------------------------------
    END

    unless($test) {
        # Treat overloaded objects as numbers if we're asked to do a
        # numeric comparison.
        my $unoverload = $NUMERIC_CMPS{$type}
            ? \&unoverload_num
            : \&unoverload_str;

        $unoverload->(\$got, \$expect);

        if( $type =~ /^(eq|==)$/ ) {
            push @diag => $class->_is_diag( $got, $type, $expect );
        }
        elsif( $type =~ /^(ne|!=)$/ ) {
            push @diag => $class->_isnt_diag( $got, $type );
        }
        else {
            push @diag => $class->_cmp_diag( $got, $type, $expect );
        }
    }

    return($test, @diag);
}

sub is_eq {
    my($class, $got, $expect) = @_;

    if( !defined $got || !defined $expect ) {
        # undef only matches undef and nothing else
        my $test = !defined $got && !defined $expect;
        return ($test, $test ? () : $class->_is_diag($got, 'eq', $expect));
    }

    return $class->cmp_check($got, 'eq', $expect);
}

sub is_num {
    my($class, $got, $expect) = @_;

    if( !defined $got || !defined $expect ) {
        # undef only matches undef and nothing else
        my $test = !defined $got && !defined $expect;
        return ($test, $test ? () : $class->_is_diag($got, '==', $expect));
    }

    return $class->cmp_check($got, '==', $expect);
}

sub isnt_eq {
    my($class, $got, $dont_expect) = @_;

    if( !defined $got || !defined $dont_expect ) {
        # undef only matches undef and nothing else
        my $test = defined $got || defined $dont_expect;
        return ($test, $test ? () : $class->_isnt_diag($got, 'ne'));
    }

    return $class->cmp_check($got, 'ne', $dont_expect);
}

sub isnt_num {
    my($class, $got, $dont_expect) = @_;

    if( !defined $got || !defined $dont_expect ) {
        # undef only matches undef and nothing else
        my $test = defined $got || defined $dont_expect;
        return ($test, $test ? () : $class->_isnt_diag($got, '!='));
    }

    return $class->cmp_check($got, '!=', $dont_expect);
}

sub regex_check {
    my($class, $thing, $got_regex, $cmp) = @_;

    my $regex = is_regex($got_regex);
    return (0, "    '$got_regex' doesn't look much like a regex to me.")
        unless $regex;

    my $ctx = context();
    my ($p, $file, $line) = $ctx->call;

    my $test;
    my $mock = qq{#line $line "$file"\n};

    my @warnings;
    my ($success, $error) = try {
        # No point in issuing an uninit warning, they'll see it in the diagnostics
        no warnings 'uninitialized';
        ## no critic (BuiltinFunctions::ProhibitStringyEval)
        protect { eval $mock . q{$test = $thing =~ /$regex/ ? 1 : 0; 1} || die $@ };
    };

    return (0, "Exception: $error") unless $success;

    my $negate = $cmp eq '!~';

    $test = !$test if $negate;

    unless($test) {
        $thing = defined $thing ? "'$thing'" : 'undef';
        my $match = $negate ? "matches" : "doesn't match";
        my $diag = sprintf(qq{                  \%s\n    \%13s '\%s'\n}, $thing, $match, $got_regex);
        return (0, $diag);
    }

    return (1);
}

sub can_check {
    my ($us, $proto, $class, @methods) = @_;

    my @diag;
    for my $method (@methods) {
        my $ok;
        my ($success, $error) = try { $ok = $proto->can($method) };
        if ($success) {
            push @diag => "    $class\->can('$method') failed" unless $ok;
        }
        else {
            push @diag => "    $class\->can('$method') failed with an exception:\n$error"
        }
    }

    return (!@diag, @diag)
}

sub isa_check {
    my($us, $thing, $class, $thing_name) = @_;

    my ($whatami, $try_isa, $diag, $type);
    if( !defined $thing ) {
        $whatami = 'undef';
        $$thing_name = "undef" unless defined $$thing_name;
        $diag = defined $thing ? "'$$thing_name' isn't a '$class'" : "'$$thing_name' isn't defined";
    }
    elsif($type = blessed $thing) {
        $whatami = 'object';
        $try_isa = 1;
        $$thing_name = "An object of class '$type'" unless defined $$thing_name;
        $diag = "The object of class '$type' isn't a '$class'";
    }
    elsif($type = ref $thing) {
        $whatami = 'reference';
        $$thing_name = "A reference of type '$type'" unless defined $$thing_name;
        $diag = "The reference of type '$type' isn't a '$class'";
    }
    else {
        $whatami = 'class';
        $try_isa = 1;
        $$thing_name = "The class (or class-like) '$thing'" unless defined $$thing_name;
        $diag = "$thing_name isn't a '$class'";
    }

    my $ok;
    if ($try_isa) {
        # We can't use UNIVERSAL::isa because we want to honor isa() overrides
        my ($success, $error) = try {
            my $ctx = context();
            my ($p, $f, $l) = $ctx->call;
            eval qq{#line $l "$f"\n\$ok = \$thing\->isa(\$class); 1} || die $@;
        };

        die <<"        WHOA" unless $success;
WHOA! I tried to call ->isa on your $whatami and got some weird error.
Here's the error.
$error
        WHOA
    }
    else {
        # Special case for isa_ok( [], "ARRAY" ) and like
        $ok = UNIVERSAL::isa($thing, $class);
    }

    return ($ok) if $ok;
    return ($ok, "    $diag\n");
}

sub new_check {
    my($us, $class, $args, $object_name) = @_;

    $args ||= [];

    my $obj;
    my($success, $error) = try {
        my $ctx = context();
        my ($p, $f, $l) = $ctx->call;
        eval qq{#line $l "$f"\n\$obj = \$class\->new(\@\$args); 1} || die $@;
    };
    if($success) {
        my ($ok, @diag) = $us->isa_check($obj, $class, \$object_name);
        my $name = "$object_name isa '$class'";
        return ($obj, $name, $ok, @diag);
    }
    else {
        $class = 'undef' unless defined $class;
        return (undef, "$class->new() died", 0, "    Error was:  $error");
    }
}

sub require_check {
    my ($us, $thing, $version, $force_module) = @_;

    my $ctx = context();
    my $fool_me = "#line " . $ctx->line . ' "' . $ctx->file . '"';
    my $file_exists;
    protect { $file_exists = !$version && !$force_module && -f $thing };
    my $valid_name = !grep { m/^[a-zA-Z]\w*$/ ? 0 : 1 } split /\b::\b/, $thing;

    $ctx->alert("'$thing' appears to be both a file that exists, and a valid module name, trying both.")
        if $file_exists && $valid_name && !($version || $force_module);

    my ($fsucc, $msucc, $ferr, $merr, $name);

    my $mfile = "$thing.pm";
    $mfile =~ s{::}{/}g;

    if ($file_exists && !($force_module ||defined $version)) {
        $name = "require '$thing'";
        ($fsucc, $ferr) = try { eval "$fool_me\nrequire \$thing" || die $@ }
    }

    if ($valid_name || $force_module || defined $version) {
        my $load = $force_module || 'require';
        # In cases of both, this name takes priority for legacy reasons
        $name = "$load $thing";
        $name .= " version $version" if defined $version;
        if ($INC{$mfile}) {
            $msucc = 1;
        }
        else {
            ($msucc, $merr) = try { eval "$fool_me\nrequire \$mfile" || die $@ };
        }
    }

    $ctx->throw( "'$thing' was successfully loaded as both the file '$thing' and the module '$mfile', this is probably not what you want!" )
        if $msucc && $fsucc;

    unless ($msucc || $fsucc) {
        return ("require ...", 0, "    '$thing' does not look like a file or a module name") unless $file_exists || $valid_name;

        return ("require ...", 0, "    '$thing' does not load as either a module or a file\n    File Error: $ferr\n    Module Error: $merr")
            if $file_exists && $valid_name;

        my $error = $merr || $ferr || "Unknown error";
        return ($name, 0, "    tried to $name.\n    Error:  $error");
    }

    return ("$name;", 1) unless defined $version;

    my ($ok, $error) = try { eval "$fool_me\n$thing->VERSION($version)" || die $@ };
    return ("$name", 1) if $ok;
    return ($name, 0, "    tried to $name.\n    Error:  $error");
}

sub use_check {
    my ($us, $module, @imports) = @_;
    my $version = (@imports && $imports[0] =~ m/^\d[0-9\.]+$/) ? shift(@imports) : undef;

    my ($name, $ok, @diag) = $us->require_check($module, $version, 'use');
    return ($ok, @diag) unless $ok;

    # Do the import
    my $ctx = context();
    my ($succ, $error) = try {
        my ($p, $f, $l) = $ctx->call;
        eval qq{package $p;\n#line $l "$f"\n$module->import(\@imports); 1} || die $@
    };

    return (1) if $succ;
    return (0, "    Tried to use '$module'.\n    Error:  $error");
}

sub explain {
    my ($us, @args) = @_;
    protect { require Data::Dumper };

    return map {
        ref $_
          ? do {
            my $dumper = Data::Dumper->new( [$_] );
            $dumper->Indent(1)->Terse(1);
            $dumper->Sortkeys(1) if $dumper->can("Sortkeys");
            $dumper->Dump;
          }
          : $_
    } @args;
}

sub _diag_fmt {
    my( $class, $type, $val ) = @_;

    if( defined $$val ) {
        if( $type eq 'eq' or $type eq 'ne' ) {
            # quote and force string context
            $$val = "'$$val'";
        }
        else {
            # force numeric context
            unoverload_num($val);
        }
    }
    else {
        $$val = 'undef';
    }

    return;
}

sub _is_diag {
    my( $class, $got, $type, $expect ) = @_;

    $class->_diag_fmt( $type, $_ ) for \$got, \$expect;

    return <<"DIAGNOSTIC";
         got: $got
    expected: $expect
DIAGNOSTIC
}

sub _isnt_diag {
    my( $class, $got, $type ) = @_;

    $class->_diag_fmt( $type, \$got );

    return <<"DIAGNOSTIC";
         got: $got
    expected: anything else
DIAGNOSTIC
}


sub _cmp_diag {
    my( $class, $got, $type, $expect ) = @_;

    $got    = defined $got    ? "'$got'"    : 'undef';
    $expect = defined $expect ? "'$expect'" : 'undef';

    return <<"DIAGNOSTIC";
    $got
        $type
    $expect
DIAGNOSTIC
}

1;
