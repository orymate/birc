#! /bin/bash
# Copyright 2009 Mate Ory <orymate@ubuntu.com>
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.

BIRCVERSION='0.1'
if [ `id -u` -eq 0 ]
then
    echo Never run an IRC client as root. >&2
    exit 1
fi

# function to run on termination
clup ()
{
    # kill all child processes
    pkill -P $$
    rm -f $BIRCIN $BIRCCLEAN $BIRCTMP/$$.block
}
# function makes lockfile
birc_block ()
{
    touch $BIRCTMP/$$.block
}

# function removes lockfile
birc_unblock ()
{
    rm $BIRCTMP/$$.block
}

# function checks lockfile
birc_isblocked ()
{
    [ -f $BIRCTMP/$$.block ]
    return $?
}

# function gets or sets current buffer
currbuf ()
{
    if [ "x$1" = xget ]
    then
        . $BIRC_GLOBS
        echo $cb
    else
        echo "cb=$1" >> $BIRC_GLOBS
    fi
}

# dump $1 buffer to stdout and purge it
dumpbuf ()
{
    b=${1-`currbuf get`}
    if existsbuf $b
    then
        cat $BIRCTMP/$$.buf$b
        echo '' > $BIRCTMP/$$.buf$b
    fi
}

# get if $1 buffer is empty (not null) or not (null)
existsbuf ()
{
    if [ "x$1" = x ]
    then
        return -1
    else
        [ "0`stat -c %s $BIRCTMP/$$.buf$1`" -gt 1 ]
        return $?
    fi
}

# append stdin to $1 buffer
appendbuf ()
{
    cat >> $BIRCTMP/$$.buf$1 
}

# make integer from strings
strtoint ()
{
    echo "$1" | md5sum | tr -d '[a-z \-]' | \
    sed -e 's/^0*//' -e 's/^\([0-9][0-9][0-9][0-9][0-9]\).*$/\1/'
}

# catch signals
trap clup KILL 
trap clup EXIT
trap clup TERM

########## INITIAL CONFIGURATION VALUES ########################

BIRCTMP='/tmp'
BIRCPORT=6667
BIRCMOTD=true
chans[1]='queries'

########## LOAD CONFIGURATION FILES ############################

if [ -r /etc/birc/config.sh ]
then
    . /etc/birc/config.sh
fi

if [ -r $HOME/.birc/config.sh ]
then
    . $HOME/.birc/config.sh
fi

########## PRINT HELP/VERSION STRINGS ##########################

if [ x$1 = x -a x$BIRCSERVER = x ]
then
    echo $0: Usage: `basename $0` '[hostname[:port]] [nick]' >&2
    exit 1
fi

if [ x$1 = 'x--help' ]
then
    echo $0: Usage: `basename $0` '[hostname[:port]] [nick]' >&2
    cat <<.

    j<#channel_name>   join named channel
    j[channel_id]      change to last or given channel's buffer
    m[channel_id]      send message to channel until double new line or "."
                       optional argument gets current buffer
    m[nick]            send private message to last MSGed or named user
                       argument is optional in buffer 1
    r<command>         send raw irc command to server
    q[quit_msg]        disconnect and exit (has to be confirmed)

    See also birc(1) man page.
.
    exit 1
fi

if [ x$1 = 'x--version' ]
then
    echo BIRC version $BIRCVERSION >&2
    echo Copyright Mate Ory '<orymate@ubuntu.com>' 2009 >&2
    exit 1
fi

########## INTIALIZATION #######################################

# overwrite server setting if specified in command line
if [ ! x$1 = x ]
then
    BIRCSERVER=`echo $1 | sed 's/:[0-9]*//'`
    if [ ! $BIRCSERVER = $1 ]
    then
        BIRCPORT=`echo $1 | sed 's/^.*:\([0-9]*\)$/\1/'`
    fi
fi

# check temp directory
if [ ! -d $BIRCTMP -o \( -d $BIRCTMP -a ! -w $BIRCTMP \) ]
then
    echo "$0: $BIRCTMP is not a writeable directory" >&2
    exit 1
fi

# set nick to $2 or whoami if unset
if [ "x$BIRCNICK" = x ]
then
    BIRCNICK=${2-`whoami`}
fi

# create named pipe
BIRCIN=$BIRCTMP/$$.1

if [ -e $BIRCIN ]
then
    rm -f $BIRCIN || exit 1
fi

if mkfifo -m 600 $BIRCIN
then :
else
    echo $0: Unable to make named pipe $BIRCIN >&2
    exit 1
fi

# set up and touch log files

if [ x$BIRCLOG_REC = x ]
then
    BIRCLOG_REC=/dev/null
else 
    if echo Log opened: `date` >> $BIRCLOG_REC
    then :
    else
        echo $0: Unable to write $BIRCLOG_REC >&2
        BIRCLOG_REC=/dev/null
    fi
fi

if [ x$BIRCLOG_SENT = x ]
then
    BIRCLOG_SENT=/dev/null
else 
    if echo Log opened: `date` >> $BIRCLOG_SENT
    then :
    else
        echo $0: Unable to write $BIRCLOG_SENT >&2
        BIRCLOG_SENT=/dev/null
    fi
fi

# set up temporary files for buffers
for i in 1 2 3 4 5 6 7 8 9 # `seq 9`
do
    if echo '' > $BIRCTMP/$$.buf$i
    then 
        chmod 600 $BIRCTMP/$$.buf$i
        BIRCCLEAN="$BIRCCLEAN $BIRCTMP/$$.buf$i"
    else
        echo $0: Unable to create buffer file $BIRCTMP/$$.buf$i >&2
        exit 1
    fi
done

# set up global variable simulation

BIRC_GLOBS=$BIRCTMP/$$.globs
if echo 'cb=1' > $BIRC_GLOBS
then 
    chmod 600 $BIRC_GLOBS
    BIRCCLEAN="$BIRCCLEAN $BIRC_GLOBS"
else
    echo $0: Unable to create temporary file $BIRC_GLOBS >&2
    exit 1
fi

# function prints command prompt
bircprompt ()
{
    for i in 1 2 3 4 5 6 7 8 9 # `seq 9`
    do
        if existsbuf "$i"
        then
            echo -n $i
        fi
    done
    echo -n "${BIRC_PROMPT-% }";
}

########## CONNECT #############################################

tail -f "$BIRCIN" | \
# read continously request fifo
    tee -a "$BIRCLOG_SENT" | \
# log sent traffic
    telnet "$BIRCSERVER" "$BIRCPORT"  | \
# connect to IRC server
########## INBOUND PROCESSOR ##################################
while read A                          # read responses
do
    case "$A" in
        *VERSION* ) # answer ctcp version request
        echo "$A" | egrep '^:[^ ]* PRIVMSG [^ ]* :VERSION' > /dev/null \
            && echo NOTICE `echo "$A" | \
            sed 's/^:\([^ ]*\)!.*$/\1/'` ":VERSION " \
            "birc $BIRCVERSION on `uname -sr`" > $BIRCIN
        ;;
        PING* ) # pong back
        echo "$A" | sed 's/^PI/PO/' > $BIRCIN
        ;;
        *\ 372\ *|*\ 375\ * ) # print motd
        $BIRCMOTD \
            && echo "$A" | grep '^[^ ]* 37[25] [^ ]* :' > /dev/null \
            && echo "$A" | sed 's/^.*:-//' | appendbuf "`currbuf get`"
        ;;
        *\ 376\ * ) # end of motd; dump motd
        birc_isblocked || dumpbuf
        ;;
        *PRIVMSG* ) # process PRIVMSGs
        . $BIRC_GLOBS
        echo "$A" | grep '^[^ ]* *PRIVMSG [^ ]* *:' >/dev/null 2>&1 || continue
        msg=`echo "$A" | sed 's/^:\([^ !]*\)![^ ]* PRIVMSG [^ ]* :/<\1> /'`
        dest=`echo "$A" | sed 's/^[^ ]* PRIVMSG *\([^ ]*\) :.*/\1/'`
        destt=`strtoint "$dest"`
        buf=${chanbufs[$destt]}
        if [ "x$buf" = x ]
        then
            buf=1
        fi
        #echo "msg: $msg, dest: $dest, destt: $destt, buf: $buf" >&2
        ${BIRC_ONMSGGET-}
        if [ "$dest" = "$BIRCNICK" ]
        then
            buf=1 # private msg
        fi
        echo -n '' # bell
        if [ "`currbuf get`" -ne "$buf" ] || birc_isblocked
        then
            echo "$msg" | appendbuf $buf
        else
            echo "$msg"
            bircprompt
        fi
        ;;
        *\ 353\ :* ) # print NAMES list
        echo "$A" \
            | sed 's/^:*[^ ]* *353 [^ ]* @ \([#&][^ ]*\) :/NAMES on \1: /' | \
            appendbuf `currbuf get`
        while read AA; echo "$AA" | grep -v ' 366 .*:' >/dev/null 2>&1 
                                                # read till 366 (end of NAMES)
        do
            echo "$AA" | sed 's/^.*://' | appendbuf `currbuf get`
        done
        birc_isblocked || dumpbuf
        ;;
        *\ 332\ * ) # print TOPIC
        echo "$A" | grep '^:*[^:]*332 [^ :]* [^: ]* :' >/dev/null 2>&1 \
            && echo "$A" | sed 's/^.*\([&#][^ ]*\)[^:]*:/TOPIC of \1: /' | \
            appendbuf `currbuf get`
        birc_isblocked || dumpbuf
        ;;
    esac
    echo "$A" >> $BIRCLOG_REC # log received traffic
done  &

########## REGISTRING #############################################


echo Connecting...

if [ ! x$BIRCPW = x ] # if password set
then
    echo PASS $BIRCPW > $BIRCIN # send it to server
                                # (never tested)
fi

# set defaults for ident and host
if [ "x$BIRCIDENT" = x ] 
then
    BIRCIDENT=`whoami`
fi
BIRCHOSTNAME=`hostname`

sleep 1 # timing magic. it works... mostly... :/
# some LF magic and registration per RFC
cat > $BIRCIN <<.  


NICK $BIRCNICK
USER $BIRCIDENT $BIRCHOSTNAME $BIRCSERVER :${BIRCNAME-birc}
.

${BIRC_ONREGISTERED-}

########## USER INTERFACE #######################################

#initial values
quit_confirmed=false        # if there was a "q" in the session
CHAN_NUM=1                  # number of last buffer

while bircprompt; read -n1 -e A >/dev/null 2>&1 
# print prompt and read first character of command
# suppress line feed with output redirection
do
    echo -n "$A" # echo typed character
    birc_block # block output while typing
    case "$A" in
        j ) # join / buffer change
        if read -et30 AA # read end of command
        then :
        else
            echo "#"
            continue # timeout
        fi
        if echo "$AA" | grep '^[1-9]$' > /dev/null
        then # change to given buffer
            lastbuf=`currbuf get`
            currbuf "$AA" > /dev/null
            echo ${chans["$AA"]}
        elif [ x"$AA" = x ]
        then # alternate between buffers
            tmplastbuf=`currbuf get`
            currbuf "$lastbuf" > /dev/null
            echo ${chans["$lastbuf"]}
            dumpbuf $lastbuf
            lastbuf=$tmplastbuf
        else # join given channel
            if [ "$CHAN_NUM" -ge 9 ]
            then
                echo "You can only join 8 channels. Aboring." >&2
                continue;
            fi
            let 'CHAN_NUM += 1'
            echo "Joining $AA [$CHAN_NUM]"
            echo "JOIN $AA" >> $BIRCIN 
            chans[$CHAN_NUM]="$AA"
            chanbufs[`strtoint "$AA"`]="$CHAN_NUM"
            echo "chanbufs[`strtoint "$AA"`]=\"$CHAN_NUM\" # $AA" >> $BIRC_GLOBS
            lastbuf=`currbuf get`
            currbuf $CHAN_NUM
        fi
        ;;
        m ) # message
        if read -et30 AA
        then 
            if [ "x$AA" = x ] # send msg to current buffer
            then
                if [ "`currbuf get`" -eq 1 ] # if query buffer, to last nick
                then
                    if [ "x$lastmsgd" = x ]
                    then
                        echo "Unspecified MSG destination." >&2
                        continue
                    fi
                    AA=$lastmsgd
                    lastmsgd=$AA
                else
                    AA="`currbuf get`"
                fi
            fi
        else
            echo "#"
            continue # timeout
        fi
        # read msg texts
        while read -t ${BIRC_MSG_TOUT-10} -rep "${chans[$AA]-$AA}~~ " M &&
            [ ! "$M" = '.' -a ! "x$M" = x ]
        do
            echo "PRIVMSG ${chans[$AA]-$AA} :$M" >> $BIRCIN # send msg
            echo "$AA" | grep '^ [^#&]' && chans[1]=`echo "$AA" | sed 's/^ //'`
        done
        ;;
        r ) # raw command
        if read -et30 AA
        then :
        else
            echo "#"
            continue
        fi
        echo "$AA" >> $BIRCIN
        ;;
        q ) # quit
        if $quit_confirmed
        then
            if read -et30 AA # read quit msg
            then :
            else
                continue
            fi
            echo "QUIT :${AA-bye}" >> $BIRCIN & # let the server close connection
            sleep 2
            exit 0
        else
            quit_confirmed=true
            echo ? # ed style
        fi
        ;;
        * ) # default
        echo ?
        ;;
    esac
    birc_unblock # reset
    dumpbuf
done
