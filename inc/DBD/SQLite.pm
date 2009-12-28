#line 1
package DBD::SQLite;

use 5.006;
use strict;
use DBI   1.57 ();
use DynaLoader ();

use vars qw($VERSION @ISA);
use vars qw{$err $errstr $drh $sqlite_version};
BEGIN {
    $VERSION = '1.25';
    @ISA     = ('DynaLoader');

    # Initialize errors
    $err     = undef;
    $errstr  = undef;

    # Driver singleton
    $drh = undef;

    # sqlite_version cache
    $sqlite_version = undef;
}

__PACKAGE__->bootstrap($VERSION);

sub driver {
    $drh or
    $drh = DBI::_new_drh( "$_[0]::dr", {
        Name        => 'SQLite',
        Version     => $VERSION,
        Attribution => 'DBD::SQLite by Matt Sergeant et al',
    } );
}

sub CLONE {
    undef $drh;
}

package DBD::SQLite::dr;

sub connect {
    my ($drh, $dbname, $user, $auth, $attr) = @_;

    # Default PrintWarn to the value of $^W
    unless ( defined $attr->{PrintWarn} ) {
        $attr->{PrintWarn} = $^W ? 1 : 0;
    }

    my $dbh = DBI::_new_dbh( $drh, {
        Name => $dbname,
    } );

    my $real = $dbname;
    if ( $dbname =~ /=/ ) {
        foreach my $attrib ( split(/;/, $dbname) ) {
            my ($key, $value) = split(/=/, $attrib, 2);
            if ( $key eq 'dbname' ) {
                $real = $value;
            } else {
                $attr->{$key} = $value;
            }
        }
    }

    # To avoid unicode and long file name problems on Windows,
    # convert to the shortname if the file (or parent directory) exists.
    if ( $^O =~ /MSWin32|cygwin/ and $real ne ':memory:' ) {
        require Win32;
        require File::Basename;
        my ($file, $dir, $suffix) = File::Basename::fileparse($real);
        my $short = Win32::GetShortPathName($real);
        if ( $short && -f $short ) {
            # Existing files will work directly.
            $real = $short;
        } elsif ( -d $dir ) {
            # We are creating a new file.
            # Does the directory it's in at least exist?
            $real = join '', grep { defined } Win32::GetShortPathName($dir), $file, $suffix;
        } else {
            # SQLite can't do mkpath anyway.
            # So let it go through as it and fail.
        }
        if ( $^O eq 'cygwin' ) {
            if ( $] >= 5.010 ) {
                $real = Cygwin::win_to_posix_path($real, 'absolute');
            }
            else {
                require Filesys::CygwinPaths;
                $real = Filesys::CygwinPaths::fullposixpath($real);
            }
        }
    }

    # Hand off to the actual login function
    DBD::SQLite::db::_login($dbh, $real, $user, $auth) or return undef;

    # Install perl collations
    my $perl_collation        = sub { $_[0] cmp $_[1] };
    my $perl_locale_collation = sub { use locale; $_[0] cmp $_[1] };
    $dbh->func( "perl",       $perl_collation,        "create_collation" );
    $dbh->func( "perllocale", $perl_locale_collation, "create_collation" );

    # HACK: Since PrintWarn = 0 doesn't seem to actually prevent warnings
    # in DBD::SQLite we set Warn to false if PrintWarn is false.
    unless ( $attr->{PrintWarn} ) {
        $attr->{Warn} = 0;
    }

    return $dbh;
}

package DBD::SQLite::db;

sub prepare {
    my $dbh = shift;
    my $sql = shift;

    my $sth = DBI::_new_sth( $dbh, {
        Statement => $sql,
    } );

    DBD::SQLite::st::_prepare($sth, $sql, @_) or return undef;

    return $sth;
}

sub _get_version {
    return ( DBD::SQLite::db::FETCH($_[0], 'sqlite_version') );
}

my %info = (
    17 => 'SQLite',       # SQL_DBMS_NAME
    18 => \&_get_version, # SQL_DBMS_VER
    29 => '"',            # SQL_IDENTIFIER_QUOTE_CHAR
);

sub get_info {
    my($dbh, $info_type) = @_;
    my $v = $info{int($info_type)};
    $v = $v->($dbh) if ref $v eq 'CODE';
    return $v;
}

# SQL/CLI (ISO/IEC JTC 1/SC 32 N 0595), 6.63 Tables
# Based on DBD::Oracle's
# See also http://www.ch-werner.de/sqliteodbc/html/sqliteodbc_8c.html#a117
sub table_info {
    my ($dbh, $cat_val, $sch_val, $tbl_val, $typ_val) = @_;

    my @where = ();
    my $sql;
    if (   defined($cat_val) && $cat_val eq '%'
       && defined($sch_val) && $sch_val eq '' 
       && defined($tbl_val) && $tbl_val eq '')  { # Rule 19a
            $sql = <<'END_SQL';
SELECT NULL TABLE_CAT
     , NULL TABLE_SCHEM
     , NULL TABLE_NAME
     , NULL TABLE_TYPE
     , NULL REMARKS
END_SQL
    }
    elsif (   defined($sch_val) && $sch_val eq '%' 
          && defined($cat_val) && $cat_val eq '' 
          && defined($tbl_val) && $tbl_val eq '') { # Rule 19b
            $sql = <<'END_SQL';
SELECT NULL      TABLE_CAT
     , NULL      TABLE_SCHEM
     , NULL      TABLE_NAME
     , NULL      TABLE_TYPE
     , NULL      REMARKS
END_SQL
    }
    elsif (    defined($typ_val) && $typ_val eq '%' 
           && defined($cat_val) && $cat_val eq '' 
           && defined($sch_val) && $sch_val eq '' 
           && defined($tbl_val) && $tbl_val eq '') { # Rule 19c
            $sql = <<'END_SQL';
SELECT NULL TABLE_CAT
     , NULL TABLE_SCHEM
     , NULL TABLE_NAME
     , t.tt TABLE_TYPE
     , NULL REMARKS
FROM (
     SELECT 'TABLE' tt                  UNION
     SELECT 'VIEW' tt                   UNION
     SELECT 'LOCAL TEMPORARY' tt
) t
ORDER BY TABLE_TYPE
END_SQL
    }
    else {
            $sql = <<'END_SQL';
SELECT *
FROM
(
SELECT NULL         TABLE_CAT
     , NULL         TABLE_SCHEM
     , tbl_name     TABLE_NAME
     ,              TABLE_TYPE
     , NULL         REMARKS
     , sql          sqlite_sql
FROM (
    SELECT tbl_name, upper(type) TABLE_TYPE, sql
    FROM sqlite_master
    WHERE type IN ( 'table','view')
UNION ALL
    SELECT tbl_name, 'LOCAL TEMPORARY' TABLE_TYPE, sql
    FROM sqlite_temp_master
    WHERE type IN ( 'table','view')
UNION ALL
    SELECT 'sqlite_master'      tbl_name, 'SYSTEM TABLE' TABLE_TYPE, NULL sql
UNION ALL
    SELECT 'sqlite_temp_master' tbl_name, 'SYSTEM TABLE' TABLE_TYPE, NULL sql
)
)
END_SQL
            if ( defined $tbl_val ) {
                    push @where, "TABLE_NAME LIKE '$tbl_val'";
            }
            if ( defined $typ_val ) {
                    my $table_type_list;
                    $typ_val =~ s/^\s+//;
                    $typ_val =~ s/\s+$//;
                    my @ttype_list = split (/\s*,\s*/, $typ_val);
                    foreach my $table_type (@ttype_list) {
                            if ($table_type !~ /^'.*'$/) {
                                    $table_type = "'" . $table_type . "'";
                            }
                            $table_type_list = join(", ", @ttype_list);
                    }
                    push @where, "TABLE_TYPE IN (\U$table_type_list)" if $table_type_list;
            }
            $sql .= ' WHERE ' . join("\n   AND ", @where ) . "\n" if @where;
            $sql .= " ORDER BY TABLE_TYPE, TABLE_SCHEM, TABLE_NAME\n";
    }
    my $sth = $dbh->prepare($sql) or return undef;
    $sth->execute or return undef;
    $sth;
}

sub primary_key_info {
    my($dbh, $catalog, $schema, $table) = @_;

    # This is a hack but much simpler than using pragma index_list etc
    # also the pragma doesn't list 'INTEGER PRIMARK KEY' autoinc PKs!
    my @pk_info;
    my $sth_tables = $dbh->table_info($catalog, $schema, $table, '');
    while ( my $row = $sth_tables->fetchrow_hashref ) {
        my $sql = $row->{sqlite_sql} or next;
        next unless $sql =~ /(.*?)\s*PRIMARY\s+KEY\s*(?:\(\s*(.*?)\s*\))?/si;
        my @pk = split /\s*,\s*/, $2 || '';
        unless ( @pk ) {
            my $prefix = $1;
            $prefix =~ s/.*create\s+table\s+.*?\(\s*//si;
            $prefix = (split /\s*,\s*/, $prefix)[-1];
            @pk = (split /\s+/, $prefix)[0]; # take first word as name
        }
        my $key_seq = 0;
        foreach my $pk_field (@pk) {
            push @pk_info, {
                TABLE_SCHEM => $row->{TABLE_SCHEM},
                TABLE_NAME  => $row->{TABLE_NAME},
                COLUMN_NAME => $pk_field,
                KEY_SEQ     => ++$key_seq,
                PK_NAME     => 'PRIMARY KEY',
            };
        }
    }

    my $sponge = DBI->connect("DBI:Sponge:", '','')
        or return $dbh->DBI::set_err($DBI::err, "DBI::Sponge: $DBI::errstr");
    my @names = qw(TABLE_CAT TABLE_SCHEM TABLE_NAME COLUMN_NAME KEY_SEQ PK_NAME);
    my $sth = $sponge->prepare( "column_info $table", {
        rows          => [ map { [ @{$_}{@names} ] } @pk_info ],
        NUM_OF_FIELDS => scalar @names,
        NAME          => \@names,
    }) or return $dbh->DBI::set_err(
        $sponge->err(),
        $sponge->errstr()
    );
    return $sth;
}

sub type_info_all {
    return; # XXX code just copied from DBD::Oracle, not yet thought about
#    return [
#        {
#            TYPE_NAME          =>  0,
#            DATA_TYPE          =>  1,
#            COLUMN_SIZE        =>  2,
#            LITERAL_PREFIX     =>  3,
#            LITERAL_SUFFIX     =>  4,
#            CREATE_PARAMS      =>  5,
#            NULLABLE           =>  6,
#            CASE_SENSITIVE     =>  7,
#            SEARCHABLE         =>  8,
#            UNSIGNED_ATTRIBUTE =>  9,
#            FIXED_PREC_SCALE   => 10,
#            AUTO_UNIQUE_VALUE  => 11,
#            LOCAL_TYPE_NAME    => 12,
#            MINIMUM_SCALE      => 13,
#            MAXIMUM_SCALE      => 14,
#            SQL_DATA_TYPE      => 15,
#            SQL_DATETIME_SUB   => 16,
#            NUM_PREC_RADIX     => 17,
#        },
#        [ 'CHAR', 1, 255, '\'', '\'', 'max length', 1, 1, 3,
#            undef, '0', '0', undef, undef, undef, 1, undef, undef
#        ],
#        [ 'NUMBER', 3, 38, undef, undef, 'precision,scale', 1, '0', 3,
#            '0', '0', '0', undef, '0', 38, 3, undef, 10
#        ],
#        [ 'DOUBLE', 8, 15, undef, undef, undef, 1, '0', 3,
#            '0', '0', '0', undef, undef, undef, 8, undef, 10
#        ],
#        [ 'DATE', 9, 19, '\'', '\'', undef, 1, '0', 3,
#            undef, '0', '0', undef, '0', '0', 11, undef, undef
#        ],
#        [ 'VARCHAR', 12, 1024*1024, '\'', '\'', 'max length', 1, 1, 3,
#            undef, '0', '0', undef, undef, undef, 12, undef, undef
#        ]
#    ];
}

# Taken from Fey::Loader::SQLite
sub column_info {
    my($dbh, $catalog, $schema, $table, $column) = @_;

    if ( defined $column and $column eq '%' ) {
        $column = undef;
    }

    my $sth_columns = $dbh->prepare( "PRAGMA table_info('$table')" );
    $sth_columns->execute;

    my @names = qw(
        TABLE_CAT TABLE_SCHEM TABLE_NAME COLUMN_NAME
        DATA_TYPE TYPE_NAME COLUMN_SIZE BUFFER_LENGTH
        DECIMAL_DIGITS NUM_PREC_RADIX NULLABLE
        REMARKS COLUMN_DEF SQL_DATA_TYPE SQL_DATETIME_SUB
        CHAR_OCTET_LENGTH ORDINAL_POSITION IS_NULLABLE
    );

    my @cols;
    while ( my $col_info = $sth_columns->fetchrow_hashref ) {
        next if defined $column && $column ne $col_info->{name};

        my %col = (
            TABLE_NAME  => $table,
            COLUMN_NAME => $col_info->{name},
        );

        my $type = $col_info->{type};
        if ( $type =~ s/(\w+)\((\d+)(?:,(\d+))?\)/$1/ ) {
            $col{COLUMN_SIZE}    = $2;
            $col{DECIMAL_DIGITS} = $3;
        }

        $col{TYPE_NAME} = $type;

        if ( defined $col_info->{dflt_value} ) {
            $col{COLUMN_DEF} = $col_info->{dflt_value}
        }

        if ( $col_info->{notnull} ) {
            $col{NULLABLE}    = 0;
            $col{IS_NULLABLE} = 'NO';
        } else {
            $col{NULLABLE}    = 1;
            $col{IS_NULLABLE} = 'YES';
        }

        foreach my $key ( @names ) {
            next if exists $col{$key};
            $col{$key} = undef;
        }

        push @cols, \%col;
    }

    my $sponge = DBI->connect("DBI:Sponge:", '','')
        or return $dbh->DBI::set_err($DBI::err, "DBI::Sponge: $DBI::errstr");
    my $sth = $sponge->prepare( "column_info $table", {
        rows          => [ map { [ @{$_}{@names} ] } @cols ],
        NUM_OF_FIELDS => scalar @names,
        NAME          => \@names,
    } ) or return $dbh->DBI::set_err(
        $sponge->err,
        $sponge->errstr,
    );
    return $sth;
}

1;

__END__

#line 872
