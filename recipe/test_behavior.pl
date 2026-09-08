use strict;
use warnings;
use Cwd qw(getcwd);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IPC::Open3;
use Symbol qw(gensym);

my $windows = $^O eq 'MSWin32' || $^O eq 'msys';
my $prefix = $ENV{PREFIX} or die "PREFIX is required\n";
my $exe = File::Spec->catfile($prefix, 'bin', 'chktex' . ($windows ? '.exe' : ''));
my $resource = File::Spec->catfile($prefix, 'etc', 'chktexrc');
-f $resource or die "Installed resource file missing: $resource\n";
my $scratch = tempdir('chktex tests XXXXX', DIR => getcwd(), CLEANUP => 1);
chdir $scratch or die $!;
$ENV{HOME} = $scratch;
$ENV{XDG_CONFIG_HOME} = $scratch;
delete @ENV{qw(CHKTEXRC CHKTEX_HOME LOGDIR)};

sub run_checker {
    my ($program, $input) = @_;
    my $stderr = gensym;
    my $pid = open3(my $stdin, my $stdout, $stderr,
        $program, '-q', '-nall', '-w1', '-f', "%n:%l:%c:%m\n");
    print {$stdin} $input;
    close $stdin;
    my $out = do { local $/; <$stdout> } // '';
    my $err = do { local $/; <$stderr> } // '';
    waitpid($pid, 0);
    my $status = $? >> 8;
    s/\r\n/\n/g for ($out, $err);
    return ($status, $out, $err);
}

sub check_behavior {
    my ($program) = @_;
    my ($status, $out, $err) = run_checker($program,
        "\\today is fine.\n\\LaTeX{} is fine.\n");
    $status == 0 && $out eq '' && $err eq ''
        or die "Clean/resource-dependent fixture failed: $status [$out] [$err]\n";
    ($status, $out, $err) = run_checker($program, "\\LaTeX is fine.\n");
    $status == 2 && $out eq "1:1:7:Command terminated with space.\n" && $err eq ''
        or die "Known warning fixture failed: $status [$out] [$err]\n";
    print "Clean input, resource-defined silent command, and exact warning/exit status passed: $program\n";
}

check_behavior($exe);

if ($windows) {
    open my $binary, '<:raw', $exe or die $!;
    read($binary, my $dos, 64) == 64 or die "Short DOS header\n";
    seek($binary, unpack('V', substr($dos, 60, 4)), 0) or die $!;
    read($binary, my $pe, 6) == 6 or die "Short PE header\n";
    substr($pe, 0, 4) eq "PE\0\0" or die "Invalid PE header\n";
    my $machine = unpack('v', substr($pe, 4, 2));
    $machine == 0x8664 or die sprintf("Expected x64, got 0x%x\n", $machine);
    close $binary;
    print "Installed executable PE machine: 0x8664\n";

    my $relocated = File::Spec->catdir($scratch, 'relocated prefix');
    make_path("$relocated/bin", "$relocated/etc");
    copy($exe, "$relocated/bin/chktex.exe") or die $!;
    copy($resource, "$relocated/etc/chktexrc") or die $!;
    check_behavior("$relocated/bin/chktex.exe");
    unlink "$relocated/etc/chktexrc" or die $!;
    my (undef, undef, $err) = run_checker("$relocated/bin/chktex.exe", '');
    $err =~ /Could not find global resource file/
        or die "Missing-resource negative control did not report the missing file\n";
    print "Relocation with spaces and missing-resource negative control passed\n";
}
