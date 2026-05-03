#! /usr/bin/env perl

use DBI;

sub counter
{
	my ($counter) = @_;
	my ($mysql_log, $mysql_cnt);

	$mysql_log  = 'access_log';
	$mysql_cnt  = 'counters';

	unless ($dbh->do("insert $mysql_log values(NULL, " .
	                  $dbh->quote($ENV{"REMOTE_ADDR"}) . ", " .
	                  $dbh->quote($ENV{"HTTP_X_FORWARDED_FOR"}) .  ", " .
	                  $dbh->quote($ENV{"HTTP_REFERER"}) . ", " .
	                  $dbh->quote($ENV{"HTTP_USER_AGENT"}) . ", " .
	                  $dbh->quote($ENV{"HTTP_ACCEPT_LANGUAGE"}) . ", " .
	                  $dbh->quote($ENV{"HTTP_VIA"}) . ", " .
	                  $dbh->quote($ENV{"REQUEST_URI"}) . ")")) {
		return "Can't insert to log: $! $DBI::err ($DBI::errstr)";
	}
	unless ($dbh->do("insert $mysql_cnt values(1, " .
	                  $dbh->quote($counter) . ")")) {
		unless ($dbh->do("update counters set counter=counter+1 where cnt_uri=" .
		                  $dbh->quote($counter))) {
			return "Can't update counter: $! $DBI::err ($DBI::errstr), Request was: 'insert $mysql_cnt values(1, " .  $dbh->quote($counter) . ")'";
		}
	}
	return undef;
}

1;

