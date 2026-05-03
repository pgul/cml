# MIME decode

use strict;
use warnings;

use MIME::Head;
use MIME::Body;
use MIME::Entity;
use MIME::Words qw(:all);
use MIME::QuotedPrint;
use MIME::Base64;
use MIME::Parser;
use IO::Scalar;
use Text::Iconv;

our ($debug, $def_charset, $def_charsets, $encode2231, $TMPDIR);
our (@attach, %config_opts, $opt_l, $body_check_line_count);

$debug = 0 unless $debug;
$def_charset = "koi8-u" unless $def_charset;
$def_charsets = "us-ascii:koi8-r:koi8-u:windows-1251:utf-8" unless $def_charsets;
$encode2231 = 1 if !defined($encode2231);

my %canon_chrs = (
    "windows-1251" => "cp1251",
    "win-1251"     => "cp1251",
    "cp866-u"      => "cp866",
    "koi8-ru"      => "koi8-u",
    "utf8"         => "utf-8",
    "utf16"        => "utf-16",
);

sub try_xlat {
    my ($str, $from, $to, $check) = @_;
    my ($conv, $ret);
    $from =~ tr/[A-Z]/[a-z]/;
    $to =~ tr/[A-Z]/[a-z]/;
    $from =~ s/^x-//;
    $to =~ s/^x-//;
    $from =~ tr/[a-z]/[A-Z]/ if $from =~ /^iso/;
    $to =~ tr/[a-z]/[A-Z]/ if $to =~ /^iso/;
    #$from =~ s/^ISO-/ISO_/;
    #$to =~ s/^ISO-/ISO_/;
    $from = $canon_chrs{$from} if $canon_chrs{$from};
    $to = $canon_chrs{$to} if $canon_chrs{$to};
    $from = $def_charset unless $from;
    $to = $def_charset unless $to;
    return $str if $from eq $to && !defined($check);
    return $str if $str eq "";
    eval { $conv = Text::Iconv->new($from, $to) };
    return undef if !defined($conv);
    #$conv->set_attr("discard_ilseq", 1) if $to eq "utf-8";
    $str = $conv->convert($str);
    $ret = $conv->retval;
    undef($conv);
    $str = undef unless defined($ret);
$debug && print "try_xlat from $from to $to: " . (defined($str) ? "success" : "fail") . "\n";
    return $str;
}

sub xlat {
    my ($str, $from, $to) = @_;
    my ($res, $chrs);

    foreach $chrs (split(/:/, $to)) {
        $res = try_xlat($str, $from, $chrs);
$debug && print ("called try_xlat from $from to $chrs: " . (defined($res) ? "success" : "fail") . "\n");
        return ($res, $chrs) if defined($res);
    }
    return undef;
}

sub valid_string {
    my ($str, $chrs) = @_;

    return defined(try_xlat($str, $chrs, $chrs, 1)) ? 1 : undef;
}

sub unmime {
    my($filein, $fileout, $fronter, $footer, $opt_u) = @_;
    my($mess, $msgin);
    my($parser, $line, $header, $body, $lines, $i);
    $TMPDIR="/var/tmp" unless $TMPDIR;

    $parser = new MIME::Parser output_to_core => 'ALL';
    $parser->output_to_core(1);
    if (ref $filein eq 'SCALAR') {
        $msgin = $$filein;
        $mess = $parser->parse_data($$filein);
    } else {
        $mess = $parser->parse_open($filein);
    }
    unless ($mess) { # Can't parse, simple read it
        if (ref $filein eq 'SCALAR') {
            open(TMPFILE, '+>', "$TMPDIR/unmime.$$") || die "Can't create temp file: $!\n";
            unlink("$TMPDIR/unmime.$$");
            print TMPFILE $msgin;
            seek(TMPFILE, 0, 0);
            $mess = MIME::Entity->new(\*TMPFILE);
            close(TMPFILE);
        } else {
            open(MAILIN, '<', $filein) || die "Can't open $filein: $!\n";
            $mess = MIME::Entity->new(\*MAILIN);
            close(MAILIN);
        }
        #$mess->make_singlepart if $mess->head->mime_type =~ /^multipart\//i;
        # check for last boundary
        #if ($mess->head->get('Content-Type') =~ /multipart\/.*;\s*boundary=(?:"([^"]+)"|([^;\r\n\t ]+))/si)
        if ($mess->head->mime_attr('content-type') =~ /^multipart\//i)
        {   my($boundary);
            #$boundary=$1;
            $boundary = $mess->head->mime_attr('content-type.boundary');
            $debug && print "Multipart, boundary: '$boundary'\n";
            if (index($mess->stringify_body, "\n--$boundary--\r?\n")<0)
            {   # No last boundary. Add it and reparse message
                my($mess2);
                $debug && print "No last boundary, add it and reparse\n";
                if (ref $filein eq 'SCALAR')
                {
                    $msgin .= "\n--$boundary--\n";
                    $mess2 = $parser->parse_data($msgin);
                } else
                {   open(MAILIN, '<', $filein) ||
                        die "Can't open $filein: $!\n";
                    open(TMPFILE, '+>', "$TMPDIR/unmime.$$") ||
                        die "Can't create temp file: $!\n";
                    unlink("$TMPDIR/unmime.$$");
                    while ($line=<MAILIN>)
                    {   print TMPFILE $line;
                    }
                    close(MAILIN);
                    print TMPFILE "\n--$boundary--\n";
                    seek(TMPFILE, 0, 0);
                    $mess2 = $parser->parse(\*TMPFILE);
                    close(TMPFILE);
                }
                if ($mess2)
                {   $mess=$mess2;
                    undef($mess2);
                    $debug && print "Reparse successful\n";
                }
            }
        }
    }
    $mess->head->add('Mime-Version', '1.0') if !$mess->head->count('mime-version');
$debug && print "\n=================== After unmime read:\n";
$debug && $mess->print(\*STDOUT);
$debug && print "\n===================\n";
    unmime_ent($mess, $fronter, $footer, $opt_u);

    $_=$mess->head->get('Subject');
$debug && print "\ngiven subject: $_\n";
    s/^subject:\s*//i;
    #s/\r?\n\s+/ /gs;
    $_="Subject: $_";
    if ($config_opts{$opt_l,"subject_subst"} ne '') {
      print STDERR "$0: parse_header: subject subst\n$_\n" if $debug;
      my($foo) = $config_opts{$opt_l,"subject_subst"};
      eval "$foo";
      print STDERR "Substed subject:\n$_\n" if $debug;
    }
    # prepend subject prefix
    #
    #if ($config_opts{$opt_l,"subject_prefix"} ne '') {
    #  print STDERR "$0: parse_header: adding subject prefix\n" if $DEBUG;
    #  local($foo) = &config'substitute_values($config_opts{$opt_l,"subject_prefix"}, $opt_l);#';
    #  $foo =~ s/([^\\])\$XREF/$1$xref/g;  # gul
    #  local($foo_pat) = $foo;
    #  $foo_pat =~ s/(\W)/\\$1/g;
    #  s/^subject:\s*/Subject: $foo /i if !/$foo_pat/;
    #}
    # Fold subject
    $mess->head->delete('Subject');
    s/^subject:\s*//i;
    $mess->head->add('Subject', $_);

    $_=$mess->head->get('Content-Type');
    $debug && print "given content-type: $_\n";
    $mess->head->delete('content-type');
    s/^\S+:\s*//;
    $mess->head->add('Content-Type', $_);

    $body = $mess->stringify_body;
    $lines = $body =~ tr/\n//;
    $mess->head->delete('Lines');
    $mess->head->add('Lines', $lines);
$debug && print "fileout: $fileout\n";

    if (ref $fileout eq 'SCALAR') {
        $header = $mess->head->as_string;
        undef($mess);
        undef($parser);
$debug && print "===== Unmime returns:\n$header\n$body=====\n";
        $$fileout = "$header\n$body";
        return;
    }

    $fileout="$TMPDIR/resend.$$.unmime" unless $fileout;
    open(MAILOUT, '>', $fileout) || die "Can't open $fileout: $!";
$debug && print "Result wrote to [$fileout]\n";
    $mess->print(\*MAILOUT);
    close(MAILOUT);
    rename($fileout, $filein) if !$_[1] && ref $filein ne 'SCALAR';
    # do not check admin_body in the $footer
    if ($footer && ($i=index($body, $footer))>=0)
    {   $lines = substr($body, 0, $i) =~ tr/\n//;
        $body_check_line_count = $lines if $lines<$body_check_line_count;
    }
    undef($mess);
    undef($parser);
    return;
}

sub unmime_ent {
    my($mess, $fronter, $footer, $opt_u) = @_;
    my($cont_type, $head, $header, $charset, $parts, $hdr, $part, $rest, $hdr_chrs);
    my($headfield, $cont_enc, $ufronter, $ufooter, $body, $chrs, $new_hdr, $param_chrs);

    $head = $mess->head;
    $head->add('Content-Type', "text/plain") if !$mess->head->count('content-type');
    $cont_type = $head->mime_type;
    if ($cont_type =~ /^\s*$/) {
        $cont_type = "text/plain";
        $head->delete('content-type');
        $head->add('Content-Type', "text/plain");
    }
$debug && print "Unmime ent:\n";
$debug && print "=====================\n";
$debug && $mess->print(\*STDOUT);
$debug && print "\n===================\n";
    if ($cont_type =~ /^multipart\//i && ($parts = $mess->parts)<=1) {
#$debug && print "make single part\n";
        #$mess->make_singlepart;
        $cont_type = $head->mime_type;
    } elsif ($cont_type =~ /^message\/rfc822$/i) {
        $parts = $mess->parts;
    }
    $charset = $head->mime_attr('content-type.charset');
    if ($charset eq "" && $cont_type =~ /^text(\/plain)?$/i) {
        $head->mime_attr("content-type.charset" => "us-ascii");
        $charset="us-ascii";
    }
    $charset =~ tr/[A-Z]/[a-z]/;
$debug && print "Charset: $charset\n";
    if ($head->as_string =~ /[\x80-\xFF]/) {
        $hdr_chrs = $head->mime_attr('x-header-charset');
        if ($hdr_chrs eq '' || $hdr_chrs eq 'us-ascii') {
            $hdr_chrs = $charset;
        } else {
            $debug && print "Got charset from X-Header-Charset: $hdr_chrs\n";
            $head->delete('X-Header-Charset');
        }
        if ($hdr_chrs eq "us-ascii" || $hdr_chrs eq '') {
            if ($cont_type =~ /^(multipart\/)/i) {
                # get charset from part
                foreach $part ($mess->parts_DFS()) {
                    $hdr_chrs = $part->head->mime_attr('content-type.charset');
                    $hdr_chrs =~ tr/[A-Z]/[a-z]/;
                    if ($hdr_chrs && $hdr_chrs ne "us-ascii") {
                        $debug && print "Got charset from part: $hdr_chrs\n";
                        last;
                    }
                }
            }
        }
        if ($hdr_chrs eq "us-ascii" || $hdr_chrs eq '') {
            #$head->mime_attr("content-type.charset" => $def_charset);
            $hdr_chrs = $def_charset;
        }
        $header = try_xlat($head->as_string, $hdr_chrs, "utf-8");
        if (defined($header)) {
            tie *HEAD, 'IO::Scalar', \$header;
            $head = MIME::Head->read(\*HEAD);
            untie *HEAD;
        }
$debug && print "8-bit header, converted to utf-8:\n\n";
$debug && $head->print(\*STDOUT);
$debug && print "\n";
    }
    $hdr_chrs = "us-ascii";
    if ($opt_u =~ /hdr|head|all/i)
    {
        $hdr = "";
$debug && print "Decoding header...\n";
        foreach $headfield (split(/(?s)\n(?=\S)/, $head->as_string))
        {
            # convert rfc2231 params to ugly rfc2047-like form acceptable by MIME::Words
            if ($headfield =~ /^(Content-Type|Content-Disposition):/) {
                while ($headfield =~ /^(.*;)\s+([-a-z0-9*]+)\*=([-a-z0-9_+]+)'[-a-z0-9_+]*'([-=%a-z0-9.,_*]+)([;\s].*)?$/i) {
                    my ($prev, $param, $charset, $value, $post) = ($1, $2, $3, $4, $5);
                    $value =~ s/=/%3d/gs;
                    $value =~ s/%/=/gs;
                    $value = "=?$charset?q?$value?=";
                    $headfield = "$prev $param=\"$value\"$post";
                }
                while ($headfield =~ /^(.*;)\s+([-a-z0-9]+)\*0=([^ '"]+)([; ].*)?$/i ||
                       $headfield =~ /^(.*;)\s+([-a-z0-9]+)\*0='([^']+)'([; ].*)?$/i ||
                       $headfield =~ /^(.*;)\s+([-a-z0-9]+)\*0="([^"]+)"([; ].*)?$/i)
                {   my ($prev, $param, $value, $post) = ($1, $2, $3, $4);
                    my ($i) = 1;
                    while ($headfield =~ /^(.*);\s+$param\*$i=([^ '"]+)([; ].*)?$/i ||
                           $headfield =~ /^(.*);\s+$param\*$i='([^']+)'([; ].*)?$/i ||
                           $headfield =~ /^(.*);\s+$param\*$i="([^"]+)"([; ].*)?$/i)
                    {   my ($prev1, $val1, $post1) = ($1, $2, $3);
                        $headfield = "$prev1 $post1";
                        $value .= ' ' if $value =~ /\?=$/ && $val1 =~ /^=\?/;
                        $value .= $val1;
                        $i++;
                    }
                    $headfield = "$prev $param=\"$value\"$post";
                }
            }
            $hdr .= "$headfield\n";
        }
        $header = "";
        foreach (decode_mimewords($hdr)) {
            my @w=@{$_};
$debug && print "Decoded mimeword: $w[0] (chrs '$w[1]')\n";
            my $w= $w[1] ? try_xlat($w[0], $w[1], "utf-8") : $w[0];
$debug && print "Mimeword in utf-8: \'" . ($w ? $w : $w[0]) . "\'\n";
            $w =~ s/[\r\n]/ /gs if $w[1];
            $header .= $w ? $w : $w[0];
        }
        ($header, $hdr_chrs) = xlat($header, "utf-8", $def_charsets);

        # do folding
        $hdr="";
$debug && print "folding\n";
        foreach (split(/(?s)\n/, $header))
        {
$debug && print "$_\n";
            if ($_ !~ /^.{80}/ || (/=\?\S+\?=/ && $_ !~/^.{120}/))
            {   $hdr .= ($_."\n");
                next;
            }
            if ($_ !~ /^(subject|from|to|cc|apparently-to|references):/i)
            {   $hdr .= ($_."\n");
                next;
            }
            while (/^.{72}/)
            {   ($part, $rest) = ($&, $');
                if ($part =~ /(\S.*)[ \t]([^ \t]+)$/)
                {   $hdr .= "$`$1\n";
                    $_ = "\t$2$rest";
                } elsif ($rest =~ /[ \t]/)
                {   $hdr .= "$part$`\n";
                    $_ = "\t$'";
                } else
                {   last; # no spaces in the line
                }
            }
            $hdr .= ($_."\n");
        }
$debug && print "hdr_chrs: $hdr_chrs\n";
$debug && print "Folded header:\n====================\n$hdr\n";
        tie *HEAD, 'IO::Scalar', \$hdr;
        $head = MIME::Head->read(\*HEAD);
        untie *HEAD;
    } else {
        $hdr = $head->as_string;
    }
    $mess->head($head);
$debug && print "\nParts=$parts\n";
#$debug && $head->print(\*STDOUT);
#$debug && $mess->print(\*STDOUT);
#$debug && print "\n===================\n";
    if ($cont_type =~ /^(multipart\/|message\/rfc822$)/i) {
        my($alt_part, $ent, @parts);
        $alt_part = -1;
        @parts = ();
$debug && print "Loop by $parts parts...\n";
        for ($part=0; $part<$parts; $part++) {
            $ent = $mess->parts($part);
$debug && print "Checking part $part...\n";
$debug && printf "Cont-Type for part %d is %s\n", $part, $ent->head->mime_type;
            if ($opt_u =~ /only(text|html)/i &&
                $cont_type =~ /^multipart\/alternative$/i) {
                if ($ent->head->mime_type =~ /^text\/plain$/i && $opt_u =~ /onlytext/) {
                    $debug && print "hdr_chrs before calling unmime_ent: $hdr_chrs\n";
                    unmime_ent($ent, $fronter, $footer, $opt_u);
                    $debug && print "hdr_chrs after calling unmime_ent: $hdr_chrs\n";
                    @parts = ($ent);
                    $alt_part = 1;
                }
                elsif ($ent->head->mime_type =~ /^text\/html$/i && $opt_u =~ /onlyhtml/) {
                    $debug && print "hdr_chrs before calling unmime_ent: $hdr_chrs\n";
                    unmime_ent($ent, $fronter, $footer, $opt_u);
                    $debug && print "hdr_chrs after calling unmime_ent: $hdr_chrs\n";
                    @parts = ($ent);
                    $alt_part = 1;
                }
            }
            if ($alt_part < 1 && ($opt_u !~ /removeattach/ ||
                ($ent->head->mime_type =~ /^(text|message|multipart)(\/.*|\s.*|)$/i &&
                 $ent->head->mime_attr('content-disposition') !~ /attachment/i))) {
                unmime_ent($ent, $fronter, $footer, $opt_u);
                push(@parts, $ent);
            } else {
                $alt_part = 0 if $alt_part == -1;
            }
            if (($ent->head->mime_type !~ /^(text|message|multipart)(\/.*|\s.*|)$/i ||
                 $ent->head->mime_attr('content-disposition') =~ /attachment/i) &&
                $cont_type !~ /^multipart\/alternative$/i && $opt_u =~ /removeattach/) {
                # save attached document
                my (%attach, $ent_hdr, $ent_head, $name, $name2, $name_chrs);
                $attach{"cont-type"} = $ent->head->mime_type;
                $ent->head->replace('Content-Transfer-Encoding', '8bit') if $ent->head->mime_encoding ne "8bit";
                $attach{"data"} = $ent->stringify_body;
                $ent_head = $ent->head;
                $name_chrs = $ent_head->mime_attr('content-type.charset');
                $name_chrs = $charset unless $name_chrs;
                $debug && print "Attached data saved, charset $name_chrs\n";
                if ($name_chrs && $name_chrs ne "us-ascii") {
                    $ent_hdr = try_xlat($ent_head->as_string, $name_chrs, "utf-8");
                    if (defined($ent_hdr) && $ent_hdr =~ /[\x7f-\xff]/) {
                        $debug && print "Header of fileattach recoded\n";
                        tie *HEAD, 'IO::Scalar', \$ent_hdr;
                        $ent_head = MIME::Head->read(\*HEAD);
                        untie *HEAD;
                    }
                }
                #$name = $ent_head->mime_attr('content-type.name');
                #$name = $ent_head->mime_attr('content-disposition.filename') unless $name;
                #$debug && print ("Header of fileattach:\n" . $ent_head->as_string . "\n");
                #$debug && print ("given content-type: " . $ent_head->get('content-type') . "\n");
                ($name, $param_chrs) = get_param($ent_head->get('content-type'), 'name');
                ($name, $param_chrs) = get_param($ent_head->get('content-disposition'), 'filename') unless $name;
                $name2 = '';
                unless ($param_chrs) {
                    # outlook-style param? (rfc2045-encoded values)
                    foreach (decode_mimewords($name)) {
                        my @w=@{$_};
                        my $w= $w[1] ? try_xlat($w[0], $w[1], "utf-8") : $w[0];
                        $debug && print "Attach name mimeword '$name' decoded: $w[0], charset $w[1], stored $w\n";
                        $name2 .= $w ? $w : $w[0];
                    }
                } else {
                    $name2 = try_xlat($name, $param_chrs, "utf-8");
                }
                $name2 =~ s@^.*[/\\:]@@;    # basename
                ($attach{"filename"}, $attach{"name_chrs"}) = xlat($name2, "utf-8", $def_charsets);
                $debug && print "Saved attach $attach{'filename'}\n";
                push(@attach, \%attach);
            }
        }
$debug && print "alt_part = $alt_part\n";
        if ($alt_part != -1) {
$debug && print "Leave single part\n";
            $mess->parts(\@parts);
            $mess->make_singlepart;
            $cont_type = $mess->head->mime_type;
        }
        #$mess->sync_headers(Length=>'COMPUTE');
        elsif ($cont_type =~ /^multipart\//i && $mess->parts<=1) {
$debug && print "Make single part\n";
            $mess->make_singlepart;
            $cont_type = $mess->head->mime_type;
        }
        if ($cont_type =~ /^multipart\//i) {
            if ($hdr_chrs ne '' && $hdr_chrs ne 'us-ascii') {    # && $hdr_chrs ne $def_charset
#                if (defined($header = try_xlat($hdr, $hdr_chrs, $def_charset))) {
#                    tie *HEAD, 'IO::Scalar', \$header;
#                    $head = MIME::Head->read(\*HEAD);
#                    untie *HEAD;
#                    $mess->head($head);
#$debug && print "Multipart header recoded to def charset $def_charset\n";
#                } else {
$debug && print "Add header charset $hdr_chrs\n";
                    #$mess->head->mime_attr("content-type.charset" => $hdr_chrs);
                    $mess->head->delete('X-Header-Charset');
                    $mess->head->add('X-Header-Charset', $hdr_chrs);
#                }
            }
            $mess->head->delete('Content-Length');
            $mess->head->add('Content-Length', length($mess->stringify_body));
$debug && print "Message is still multipart, hdr_chrs $hdr_chrs\n";
            return;
        } elsif ($cont_type =~ /^message\/rfc822$/i) {
            $mess->head->delete('Lines');
            $mess->head->delete('Content-Length');
            $mess->head->add('Content-Length', length($mess->stringify_body));
            return;
        } else {
            $charset = $mess->head->mime_attr('content-type.charset');
#            if ($hdr_chrs ne '' && $charset ne '' && $hdr_chrs ne 'us-ascii' && $charset ne 'us-ascii' && $hdr_chrs ne $charset) {
#                if ($hdr_chrs ne 'utf-8') {
#                    if (defined($hdr = try_xlat($mess->head->as_string, $hdr_chrs, 'utf-8'))) {
#                        tie *HEAD, 'IO::Scalar', \$hdr;
#                        $head = MIME::Head->read(\*HEAD);
#                        untie *HEAD;
#                        $mess->head($head); 
#                        $debug && print "Header converted from $hdr_chrs to utf-8\n";
#                        $hdr_chrs = 'utf-8';
#                    }
#                }
#                if ($charset ne 'utf-8') {
#                    $debug && print "Message body need to be converted from $charset to utf-8\n";
#                }
                $debug && print "Result singlepart message:\n==========\n";
                $debug && print ($head->as_string . "\n" . $mess->stringify_body);
                $debug && print "==========\n";
#            }
            $fronter = $footer = "";
        }
    } #else { # not multipart
        $cont_enc = $mess->head->mime_encoding;
        $cont_enc =~ tr/[A-Z]/[a-z]/;
$debug && print "cont-enc=$cont_enc\n";
        unless ($cont_enc) {
            $mess->head->mime_encoding("7bit");
            $cont_enc="7bit";
        }
        if ($cont_enc eq "7bit" && $mess->stringify_body =~ /[\x80-\xff]/) {
            $mess->head->mime_encoding("8bit");
            $cont_enc = "8bit";
        }
        if ($cont_enc eq "8bit" && $mess->stringify_body !~ /[\x80-\xff]/) {
            $mess->head->mime_encoding("7bit");
            $cont_enc = "7bit";
            $head->mime_attr("content-type.charset" => "us-ascii");
            $charset = "us-ascii";
        }
        if ($opt_u !~ /body|all/i || $cont_type !~ /^text(\/.*)?$/i) {
            $mess->head->delete('Content-Length');
            $mess->head->add('Content-Length', length($mess->stringify_body));
            # convert header to charset in Content-Body if possible
$debug && print "Charset $charset, hdr_chrs $hdr_chrs, do not recode body\n";
            if ($hdr_chrs ne '' && $hdr_chrs !~ /us-ascii/i && $hdr_chrs ne $charset) {
                if ($charset && $charset !~ /us-ascii/i) {
                    if (defined($hdr = try_xlat($mess->head->as_string, $hdr_chrs, $charset))) {
$debug && print "Header recoded to $charset\n";
                        tie *HEAD, 'IO::Scalar', \$hdr;
                        $head = MIME::Head->read(\*HEAD);
                        untie *HEAD;
                        $mess->head($head); 
                    } else {
$debug && print "Cannot recode header to $charset\n";
                        $mess->head->delete('X-Header-Charset');
                        $mess->head->add('X-Header-Charset', $charset);
                    }
                } else {
                    if (defined($hdr = try_xlat($mess->head->as_string, $hdr_chrs, $def_charset))) {
$debug && print "Header recoded to $def_charset\n";
                        tie *HEAD, 'IO::Scalar', \$hdr;
                        $head = MIME::Head->read(\*HEAD);
                        untie *HEAD;
                        $mess->head($head); 
                    }
#                    else {
                        #$head->mime_attr("content-type.charset" => $hdr_chrs);
                        $head->delete('X-Header-Charset');
                        $head->add('X-Header-Charset', $hdr_chrs);
                        $debug && print "Added header charset $hdr_chrs\n";
#                    }
                }
            }
            return;
        }
        if ($cont_enc eq "base64" || $cont_enc eq "quoted-printable") {
            $mess->head->replace('Content-Transfer-Encoding', '8bit');
            $cont_enc = "8bit";
$debug && print "Change encoding $cont_enc -> 8bit\n";
        }
        if ($charset eq "us-ascii" && $mess->stringify_body =~ /[\x80-\xFF]/) {
            $head->mime_attr("content-type.charset" => $def_charset);
            $charset = $def_charset;
        }
        if ($cont_type eq "text/plain" ||
            $cont_type eq "text/html" && $opt_u =~ /xlat-html/) {
            $mess->head->replace('Content-Transfer-Encoding', '8bit') if ($cont_enc ne "8bit" && $cont_enc ne "7bit");
            $ufronter = $ufooter = "";
            if ($cont_type =~ m@^text(/plain)?$@i &&
                ($head->mime_attr('content-type.name') eq "") &&
                ($head->mime_attr('content-disposition.filename') eq "") &&
                ($head->mime_attr('content-disposition') !~ /attachment/i)
           ) {
                $ufronter = try_xlat($fronter, $def_charset, "utf-8") if $fronter ne "";
                $ufooter = try_xlat($footer, $def_charset, "utf-8") if $footer ne "";
            }
            $body = try_xlat($mess->bodyhandle->as_string, $charset, "utf-8");        # Is it needed?
            #$body = try_xlat($mess->stringify_body, $charset, "utf-8");        # Is it needed?
            $mess->head->mime_attr("content-type.charset" => "utf-8");
            #$body = $mess->bodyhandle->as_string;
            $body .= "\n" unless $body =~ /\n$/s;
            $body = $ufronter . $body . $ufooter;
$debug && print "UTF-8 body after adding fronter & footer:\n==========\n$body\n==========\n";
$debug && print "Header charset $hdr_chrs\n";
            $hdr = try_xlat($mess->head->as_string, $hdr_chrs, "utf-8");
            $hdr = $mess->head->as_string unless $hdr;
            ($body, $chrs) = xlat("$hdr\n$body", "utf-8", $def_charsets);
            if (defined($body)) {
$debug && print "Result charset (header+body): $chrs\n";
$debug && print "Recoded message:\n==========\n$body\n==========\n";
                ($new_hdr, $body) = ("$`\n", $') if $body =~ /\n\n/s;
                $charset = $chrs;
                $cont_enc = "8bit" if $cont_enc eq "7bit" && $body =~ /[\x80-\xFF]/;
                if ($chrs ne $hdr_chrs && $hdr =~ /[\x80-\xFF]/) {
                    $debug && print "Header recoded from $hdr_chrs to $chrs, replacing\n";
                    tie *HEAD, 'IO::Scalar', \$new_hdr;
                    $head = MIME::Head->read(\*HEAD);
                    untie *HEAD;
                    $mess->head($head);
                }
                $hdr_chrs = $chrs;
                $head->mime_attr("content-type.charset" => $chrs);
                $mess->bodyhandle(new MIME::Body::InCore $body);
            }
            $mess->head->replace('Content-Transfer-Encoding', $cont_enc) if ($cont_enc ne "8bit" && $cont_enc ne "7bit");
$debug && print "Parsed recoded message:\n==========\n";
$debug && print ($mess->head->as_string . "\n" . $mess->stringify_body);
$debug && print "\n==========\n";
        }
    #}
$debug && print "Charset $charset, hdr_chrs $hdr_chrs\n";
    if ($hdr_chrs ne '' && $hdr_chrs ne "us-ascii" && $hdr_chrs ne $charset) {
        if (defined($hdr = try_xlat($mess->head->as_string, $hdr_chrs, $charset))) {
            tie *HEAD, 'IO::Scalar', \$hdr;
            $head = MIME::Head->read(\*HEAD);
            untie *HEAD;
            $mess->head($head);
$debug && print "header changed\n";
        } else {
            $mess->head->delete('X-Header-Charset');
            $mess->head->add('X-Header-Charset', $hdr_chrs);
            $debug && print "Cannot recode header to body charset '$charset', add X-Header-Charset: $hdr_chrs header\n";
        }
    }

    $mess->head->delete('Lines');
    #$mess->sync_headers(Length=>'COMPUTE');
    $mess->head->delete('Content-Length');
    $mess->head->add('Content-Length', length($mess->stringify_body));
    return;
}

sub mime {
    my($mess);
    my($filein, $fileout, $opt_i) = @_;
    my($parser, $body, $lines);
    $TMPDIR="/var/tmp" unless $TMPDIR;
    $fileout="$TMPDIR/resend.$$.mime" unless $fileout;

    open(MAILIN, '<', $filein) || die "Can't open $filein: $!";
    $parser = new MIME::Parser output_to_core => 'ALL';
    $parser->output_to_core(1);
    $mess = $parser->read(\*MAILIN);
    unless ($mess) { # Can't parse, simple read it
        seek(MAILIN, 0, 0) || die "Can't seek: $!";
        $mess = MIME::Entity->new(\*MAILIN);
    }
    close(MAILIN);
    $mess->head->add('Mime-Version', '1.0') if !$mess->head->count('mime-version');
#$debug && $mess->print(\*STDOUT);
#$debug && print "\n===================\n";
    mime_ent($mess, $opt_i);
    $_=$mess->head->get('content-type');
    $mess->head->delete('content-type');
    s/^\S+:\s*//;
    $mess->head->add('Content-Type', $_);
    $body = $mess->stringify_body;
    $lines = $body =~ tr/\n//;
    $mess->head->delete('Lines');
    $mess->head->add('Lines', $lines);

    open(MAILOUT, ">", $fileout) || die "Can't open $fileout: $!";
    $mess->print(\*MAILOUT);
    close(MAILOUT);
    rename($fileout, $filein) unless $_[1];
    return;
}

sub mime_ent {
    my($mess, $opt_i) = @_;
    my($cont_type, $head, $charset, $hdr_charset, $parts, $headfield);
    my($curline, $curmime, $plainword, $plainlen);
    my($header, $headtail, $mimeword, $cont_enc);

    $head = $mess->head;
    $head->add('Content-Type', "text/plain") if !$mess->head->count('content-type');
    $cont_type = $head->mime_type;
    if ($cont_type =~ /^\s*$/) {
        $cont_type = "text/plain";
        $head->delete('content-type');
        $head->add('Content-Type', "text/plain");
    }
#$debug && $mess->print(\*STDOUT);
#$debug && print "\n===================\n";
    $charset = $head->mime_attr('content-type.charset');
    if ($charset eq "" && $cont_type =~ /^text(\/plain)?$/i) {
        $head->mime_attr("content-type.charset" => "us-ascii");
        $charset="us-ascii";
    }
    $charset =~ tr/[A-Z]/[a-z]/;
    if ($head->as_string =~ /[\x80-\xFF]/) {
        if ($charset eq "us-ascii" && $cont_type =~ /^text/i) {
            $head->mime_attr("content-type.charset" => $def_charset);
            $charset = $def_charset;
            #$head->mime_attr("content-type.charset" => "x-cp866");
            #$charset = "x-cp866";
        }
#        if (($header = xlat($head->as_string, $charset, $def_charset)) ne "") {
#            tie *HEAD, 'IO::Scalar', \$header;
#            $head = MIME::Head->read(\*HEAD);
#            untie *HEAD;
#$debug && print "$header\n\n";
#$debug && $head->print(\*STDOUT);
#        }
    }
$debug && $head->print(\*STDOUT);
    if ($opt_i =~ /hdr|head|all/i && $head->as_string =~ /[\x80-\xFF]/)
    {
        $header = "";
        $hdr_charset = $head->mime_attr('x-header-charset');
        if ($hdr_charset =~ /^us-ascii$/i || !$hdr_charset)
        {   $hdr_charset = $charset;
        }
        if ($hdr_charset =~ /^us-ascii$/i || !$hdr_charset)
        {   $hdr_charset = $def_charset;
        }
$debug && print "Encoding header...\n";
#        #encode_mimewords does not work correctly :-(
#        foreach (encode_mimewords($head->as_string)) {
#            local @w=@{$_};
#            local $w= xlat($w[0], $w[1] ? $w[1] : $def_charset, $def_charset);
#$debug && print "Mimeword: \'" . ($w ? $w : $w[0]) . "\'\n";
#            $header .= $w ? $w : $w[0];
#        }
        foreach $headfield (split(/(?s)\n(?=\S)/, $head->as_string))
        {   if ($headfield !~ /[\x80-\xFF]/)
            {   $header .= "$headfield\n";
                next;
            }
            # Encode parameters by RFC2231
            if ($headfield =~ /^(Content-Type|Content-Disposition):/i) {
                #$debug && print "Check for RFC2231 params: $headfield";
                while ($headfield =~ /(;\s+[-a-z0-9]+)=([^ '";]*[\x80-\xFF][^ '";]*)([;\s].*)?$/is ||
                       $headfield =~ /(;\s+[-a-z0-9]+)='([^']*[\x80-\xFF][^']*)'([;\s].*)?$/is ||
                       $headfield =~ /(;\s+[-a-z0-9]+)="([^"]*[\x80-\xFF][^"]*)"([;\s].*)?$/is)
                {   my ($prev1, $prev2, $param, $post) = ($`, $1, $2, $3);
                    if ($encode2231)
                    {   $param =~ s/[^a-zA-Z0-9.]/sprintf('%%%02X', ord($&))/ge;
                        $headfield = "$prev1$prev2*=$hdr_charset''$param$post";
                        $debug && print "RFC2231-encoded: $hdr_charset''$param\n";
                    } else
                    {   $param =~ s/[^a-zA-Z0-9. ]/sprintf('=%02X', ord($&))/ge;
                        $param =~ s/ /_/g;
                        $headfield = "$prev1$prev2=\"=?$hdr_charset?Q?$param$post?=\"";
                    }
                }
                if ($headfield !~ /[\x80-\xFF]/)
                {   $header .= "$headfield\n";
                    next;
                }
            }
            # Do not mime start (7-bit) part
            $curline = "";
            if ($headfield =~ /^[-a-zA-Z0-9 \t_@!~`#\$\%^&*()=|\\?<>,.'":;\[\]{}\/\t\n]+[:\s]\s*(?=\S)/s)
            {   $curline = $&;
                $headfield = $';
                $curline .= " " if $curline =~ /:$/;
            }
            $headtail = "";
            if ($headfield =~ /\s[-a-zA-Z0-9 \t_@!~`#\$\%^&*()=|\\?<>,.'";:\[\]{}\/\n]+$/s)
            {   $headtail = $&;
                $headfield = $`;
            }

            # $headfield =~ s/\n\s+/ /gs;
$debug && print "curline='$curline', headfield='$headfield', headtail='$headtail'\n";

            # MIME the rest as 36-bytes base64 words
            $curmime = 0;
            while ($headfield ne "")
            {
                if ($headfield =~ /^(.{1,46}?)(\s+[-a-zA-Z0-9_@!~`#\$\%^&*()=|\\?<>,.'";:\[\]{}\/][-a-zA-Z0-9_@!~`#\$\%^&*()=|\\?<>,.'";:\[\]{}\/ \t\n]*\s)/s)
                {
                    # Encode first word and leave unencoded next one
                    ($mimeword, $plainword, $headfield) = ($1, $2, $');
                } else
                {
                    $headfield =~ /^.{1,42}/s || die "MIME internal error, headfield: '$headfield'\n";
                    ($headfield, $mimeword, $plainword) = ($', $&, "");
                    # Do not split across utf8 character
                    while (length($mimeword) < 46 && !valid_string($mimeword, $hdr_charset) && $headfield =~ /^./) {
                        $headfield = $';
                        $mimeword .= $&;
                    }
                }
$debug && print "mimeword='$mimeword', plainword='$plainword', headfield='$headfield'\n";
                $mimeword =~ s/\n\s+/ /gs; # Is it really needed?
                $mimeword = encode_mimeword($mimeword, 'B', $hdr_charset);
                $mimeword =~ s/\n//gs;  # workaround
                if (length($curline)+length($mimeword)>140)
                {   $header .= ($curline . "\n");
                    $curline = "\t";
                    $header =~ s/(.)\s+\n$/$1\n/s;
                    $curmime = 0;
                }
                $curline .= " " if $curmime;
                $curline .= $mimeword;
                $curmime = 1;
                if ($plainword ne "")
                {
                    my ($plainlen) = length($plainword);
                    $plainlen = length($`) if $plainword =~ /\n/;
                    if (length($curline)+$plainlen>140)
                    {   $header .= $curline . "\n";
                        $curline = "\t";
                        $header =~ s/(.)\s+\n$/$1\n/s;
                        $plainword =~ s/^\s+//;
                    }
                    $curline .= $plainword;
                    if ($curline =~ /^.*\n/) {
                        $header .= $&;
                        $curline = $';
                    }
                    $curmime = 0;
$debug && print "plainword added to curline, now curline is '$curline'\n";
                }
            }
            $header .= ($curline.$headtail."\n");
        }
        tie *HEAD, 'IO::Scalar', \$header;
        $head = MIME::Head->read(\*HEAD);
        untie *HEAD;
        $head->delete('x-header-charset');
    }
    $mess->head($head);
$debug && print "\nEncoded header:\n==============\n$header\n\n";
$debug && print "\nParsed header:\n==============\n";
$debug && $head->print(\*STDOUT);

#$debug && print "\nParts=$parts\n";
#$debug && $mess->print(\*STDOUT);
#$debug && print "\n===================\n";
    if ($cont_type =~ /^multipart\//i) {
        my($alt_part, $part, $ent);

        if ($head->mime_attr('content-type.charset')) {
$debug && print "Remove charset in multipart\n";
            $head->mime_attr('content-type.charset' => undef);
        }
        $parts = $mess->parts;
$debug && print "Loop by $parts parts...\n";
        for ($part=0; $part<$parts; $part++) {
            $ent = $mess->parts($part);
$debug && print "Checking part $part...\n";
$debug && printf "Cont-Type for part %d is %s\n", $part, $ent->head->mime_type;
            mime_ent($ent, $opt_i);
        }
        $mess->head->delete('Content-Length');
        $mess->head->add('Content-Length', length($mess->stringify_body));
        return;
    }
    $cont_enc = $mess->head->mime_encoding;
    $cont_enc =~ tr/[A-Z]/[a-z]/;
$debug && print "cont-enc=$cont_enc\n";
    unless ($cont_enc) {
        $mess->head->mime_encoding("7bit");
        $cont_enc="7bit";
    }
    if ($cont_enc eq "7bit" && $mess->stringify_body =~ /[\x80-\xff]/ && $cont_type =~ /^text(\/.*)?$/i) {
        $mess->head->mime_encoding("8bit");
        $cont_enc = "8bit";
    }
    return unless $opt_i =~ /body|all/i;
    return unless $mess->stringify_body =~ /[\x80-\xff]/ || $mess->stringify_body =~ /[^\n]{900}/s;
    #$mess->body(encode_base64($mess->stringify_body));
    $mess->head->replace('Content-Transfer-Encoding', 'base64');
    $cont_enc = "base64";
    $mess->head->delete('Content-Length');
    $mess->head->add('Content-Length', length($mess->stringify_body));
    return;
}

sub rfc2231percent
{
    my ($str) = @_;
    $str =~ s/%([0-9a-fA-F]{2})/pack("c", hex($1))/ge;
    return $str;
}

sub param_hash
{
    my ($raw) = @_;
    my (%params, $param, $val);

    # Get raw field, and unfold it:
    $raw = '' if !defined($raw);
    $raw =~ s/\n//g;
    $raw =~ s/\s+$//;              # Strip trailing whitespace

    # Extract special first parameter:
    $raw =~ m/\A(?:\s|\([^\)]*\))*([^\s\;\x00-\x1f\x80-\xff]+)(?:\s|\([^\)]*\))*/og or return {};
    $params{'_'} = $1;
    $debug && print "params{'_'} = '$params{'_'}\n";

    # Extract subsequent parameters.
    # No, we can't just "split" on semicolons: they're legal in quoted strings!
    while (1) {  # keep chopping away until done...
        $raw =~ m/\G(?:\s|\([^\)]*\))*\;(?:\s|\([^\)]*\))*/og or last;  # skip leading separator
        $raw =~ m/\G([^\x00-\x1f\x80-\xff :=]+)\s*=\s*/og or last;  # give up if not a param
        $param = lc($1);
        $raw =~ m/\G(\"([^\"]*)\")|\G(=\\?[^?]*\\?[A-Za-z]\\?[^?]+\\?=)|\G([^;]+)|\G([^ \x00-\x1f\x80-\xff\Q()<>@,;:\<\/\[\]?=\E\"]+)/g or last;  # give up if no value
        my ($qstr, $str, $enctoken, $badtoken, $token) = ($1, $2, $3, $4, $5);
        if (defined($badtoken)) {
            # Strip leading/trailing whitespace from badtoken
            $badtoken =~ s/^\s*//;
            $badtoken =~ s/\s*$//;
        }
        $val = defined($qstr) ? $str :
               (defined($enctoken) ? $enctoken :
                (defined($badtoken) ? $badtoken : $token));
        $params{$param} = $val;
        $debug && print "params{'$param'} = '$params{$param}\n";
    }
    return %params;
}

sub get_param
{
    my ($val, $param) = @_;
    my (%param, $enc, $i, $p0);

    $debug && print "get_param($val, $param)\n";
    %param = param_hash($val);
    return $param{$param} if defined($param{$param});
    return (rfc2231percent($2), $1) if $param{"$param*"} =~ /^([^']*)'[^']*'(.*)$/;
    if (defined($param{$p0="$param*0*"}) || defined($param{$p0="$param*0"})) {
        return undef unless $param{$p0} =~ /^([^']*)'[^']*'(.*)$/;
        ($enc, $val) = ($1, $2);
        if (!defined($param{"$param*0"})) {
            $val = rfc2231percent($val);
        }
        for ($i=1; defined($param{"$param*$i*"}) || defined($param{"$param*$i"}); $i++) {
            if (defined($param{"$param*$i"})) {
                $val .= $param{"$param*$i"};
            } else {
                $val .= rfc2231percent($param{"$param*$i*"});
            }
        }
        return $val;
    }
    return undef;
}

1;

