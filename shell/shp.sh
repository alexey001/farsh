#!/bin/bash


CFGDIR=/etc/netinit
DB="/etc/netinit/shdb.db"
DBT='shp'
DBTID="freeid"

dev_in="imq0"
dev_out="imq1"

ext_if="eth0.13"

DEFAULT_CLASS=65534
DEFAULT_SPEED="500mbit"
RTABLE="100"
RULE_FILE="rules_"

function db
{
sqlite3 -separator \t -batch -column -header $DB "$1"
}

IIP=`which ip`
ITC=`which tc`
IPT=`which iptables`
IPSET=`which ipset`

function db1
{
sqlite3 -separator \t -batch -column -noheader $DB "$1"
}

function db2
{
sqlite3  $DB "$1"
}


function _tc
{
$ITC $@
}

function _ip
{
$IIP $@
}

function _ipt
{
$IPT $@
}

function _ipset
{
$IPSET $@
}


function trim() {
    local var=$@
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    echo -n "$var"
}

function escape_string
{
echo ${1//\//\\/}
}


function cidr_to_net() {

    local netmaskarr
  local network=(${1//\// })
  local iparr=(${network[0]//./ })
  if [[ ${network[1]} =~ '.' ]]; then
    netmaskarr=(${network[1]//./ })
  else
    if [[ $((8-${network[1]})) > 0 ]]; then
      netmaskarr=($((256-2**(8-${network[1]}))) 0 0 0)
    elif  [[ $((16-${network[1]})) > 0 ]]; then
      netmaskarr=(255 $((256-2**(16-${network[1]}))) 0 0)
    elif  [[ $((24-${network[1]})) > 0 ]]; then
      netmaskarr=(255 255 $((256-2**(24-${network[1]}))) 0)
    elif [[ $((32-${network[1]})) > 0 ]]; then 
      netmaskarr=(255 255 255 $((256-2**(32-${network[1]}))))
    fi
  fi
  
  [[ ${netmaskarr[2]} == 255 ]] && netmaskarr[1]=255
  [[ ${netmaskarr[1]} == 255 ]] && netmaskarr[0]=255
echo $(( $(( ${iparr[0]}  & ${netmaskarr[0]})) ))"."$(( $(( ${iparr[1]} & ${netmaskarr[1]})) ))"."$(($(( ${iparr[2]} & ${netmaskarr[2]})) ))"."$(($((${iparr[3]} & ${netmaskarr[3]})) ))
}


function check_db
{
db "create table IF NOT EXISTS  shp (net varchar(25) primary key,prefix int,speed ,class int,comment text);"
db "create table IF NOT EXISTS freeid (id int primary key not null);"
}


function show_shaper_db
{
db "select net || \"/\" || prefix as net,speed,class,comment from $DBT"

}

function if_shaper_init
{
    _ip link set up dev $dev_in
    _ip link set up dev $dev_out
    _tc qdisc add dev $dev_in root handle 1: hfsc 
    _tc qdisc add dev $dev_out root handle 1: hfsc 
}

function if_shaper_reset
{
    _tc qdisc del dev $dev_in root
    _tc qdisc del dev $dev_out root
}

function ipt_init
{

#    _ipt -t mangle -X CLS
#    _ipt -t mangle -N CLS

#    _ipt -t mangle -D FORWARD -i $ext_if -j TABCLAS --rtable $RTABLE --cmatch dst
#    _ipt -t mangle -D FORWARD -o $ext_if -j TABCLAS --rtable $RTABLE --cmatch src

#    _ipt -t mangle -A FORWARD -i $ext_if -j TABCLAS --rtable $RTABLE --cmatch dst
#    _ipt -t mangle -A FORWARD -o $ext_if -j TABCLAS --rtable $RTABLE --cmatch src

    _ipt -t mangle -F
    
    _ipt -t mangle -A POSTROUTING  -j TABCLAS --rtable $RTABLE --cmatch dst
    _ipt -t mangle -A POSTROUTING  -j TABCLAS --rtable $RTABLE --cmatch src

    _ipt -t mangle -A FORWARD -i $ext_if -j IMQ --todev 0
    _ipt -t mangle -A FORWARD -o $ext_if -j IMQ --todev 1




}


function shaper_route
{
local oper
local realm=$((16#$2))
case ${FUNCNAME[1]} in
    "shaper_add_route") _ip route add $1 dev lo table $RTABLE realm 1/$realm;;
    "shaper_del_route") _ip route del $1 dev lo table $RTABLE;;
esac

}

function shaper_add_route
{
shaper_route $1 $2
}

function shaper_del_route
{
shaper_route $1 $2
}


# $1 - class
# $2 - speed
# $3 - leaf qdisc
# $4 - prefix
function shaper_rule
{
local oper

case ${FUNCNAME[1]} in
    "shaper_add_rule") oper="add";;
    "shaper_del_rule") oper="del";;
    "shaper_change_rule") oper="change";;
esac

local tch=$(( 100+$1 ))
local dev
    for dev in $dev_in $dev_out
    do
	_tc "class $oper dev $dev parent 1: classid 1:$1 hfsc sc rate ${2} ul rate ${2}"
	
	if [ $oper != "del" ]
	then
	_tc "qdisc $oper dev $dev parent 1:$1 handle ${tch}: $3"
	fi
    done

}


# $1 - class
# $2 - speed
# $3 - leaf qdisc
# $4 - prefix
function shaper_add_rule
{
shaper_rule $1 $2 $3 $4
}

function shaper_del_rule
{
shaper_rule $1 $2 $3 $4
}

function shaper_change_rule
{
shaper_rule $1 $2 $3 $4
}




LB='('
RB=')'

function get_new_class
{
    row=$(trim $(db1 "SELECT id FROM $DBTID ORDER BY id DESC LIMIT 1;"))
    
    if [ "x$row" != "x" ]
	then
	db "delete from $DBTID where id=\"${row}\";"
	echo $row
	return 1
    fi
    
    row=$(trim $(db1 "select max${LB}class${RB}+1 from $DBT;"))
    if [ "x$row" != "x" ]
	then
	echo $row
	return 1
    fi
    
    echo "1"

}

# $1 - mask
function mask_to_leaf
{
if [ "$1" = "32" ]
    then
    echo "codel"
    else
    echo "fq_codel"
    fi
}

# $1 - ip
# $2 - speed
# $3 - class
# $4 - comment
function shaper_add
{
local ip=${1%/*}
local mask=${1#*/}
local class
local leaf
local iifs
local speed
local addmode="full"
local flds

speed=$2

if [ "x$mask" = "x" -o "x$mask" = "x$ip" ]
then
mask=32
fi

if [ $mask != 32 ]
then
ip=$(cidr_to_net $1)
fi



if [ "x$3" = "x" ]
    then
    class=$(get_new_class)
    else
    res=$(db2 "select class,speed from $DBT where class=\"${3}\" limit 1")
    if [ "x$res" != "x" ]
	then
	iifs=$IFS
	IFS="\|"
	flds=( $res )
	speed=${flds[1]}
        IFS=$iifs
        addmode="simp"
    fi

    class=$3
fi


db "insert into $DBT values(\"$ip\",\"$mask\",\"${speed}\",\"${class}\",\"$4\")"

leaf=$(mask_to_leaf $mask)

if [ $addmode = "full" ]
    then
    shaper_add_rule $class $2 $leaf "$ip/$mask"
    shaper_add_route "$ip/$mask" $class
    else
    shaper_add_route "$ip/$mask" $class
fi


}

#
# $1 - ip
# $2 - speed
function shaper_change
{
local ip=${1%/*}
local mask=${1#*/}
local class
local leaf
local speed
local iifs
local flds
local cntr
if [ "x$mask" = "x" -o "x$mask" = "x$ip" ]
then
mask=32
fi

res=$(db2 "select class,speed from $DBT where net=\"$ip\" and prefix=\"$mask\" limit 1")
iifs=$IFS
IFS="\|"
flds=( $res )
class=${flds[0]}
speed=${flds[1]}
IFS=$iifs


res=$(db2 "select * from $DBT where class=\"$class\";") 
for line in $res
    do
    iifs=$IFS
    IFS="\|"
    flds=( $line )
    net=${flds[0]}
    mask=${flds[1]}
    speed=${flds[2]}
    class=${flds[3]}

    leaf=$(mask_to_leaf $mask)
    IFS=$iifs

    shaper_change_rule $class $speed $leaf "${net}/${mask}"

    done 

res=$(db "update $DBT set speed=\"$2\" where class=\"$class\";")


}


function shaper_del
{
local ip=${1%/*}
local mask=${1#*/}
local class
local leaf
local speed
local iifs
local flds
local cntr
if [ "x$mask" = "x" -o "x$mask" = "x$ip" ]
then
mask=32
fi

leaf=$(mask_to_leaf $mask)

res=$(db2 "select class,speed from $DBT where net=\"$ip\" and prefix=\"$mask\" limit 1")
iifs=$IFS
IFS="\|"
flds=( $res )
class=${flds[0]}
speed=${flds[1]}
IFS=$iifs

db "delete from $DBT where net=\"$ip\" and prefix=\"$mask\""
db "insert into $DBTID values(\"${class}\")"

cntr=$(trim $(db1 "SELECT count${LB}class${RB} FROM $DBT where class=\"$class\";"))

if [ $cntr = 0 ]
then
shaper_del_rule $class $speed $leaf $1
fi
shaper_del_route $1

}

function shaper_load
{
local iifs
#IFS=\|
local res
local flds

local net
local mask
local speed
local class
local leaf

res=$(db2 "select * from $DBT;") 
for line in $res
    do
    iifs=$IFS
    IFS="\|"
    flds=( $line )
    net=${flds[0]}
    mask=${flds[1]}
    speed=${flds[2]}
    class=${flds[3]}
    
    leaf=$(mask_to_leaf $mask)
    IFS=$iifs
    shaper_add_rule $class $speed $leaf "${net}/${mask}"
    shaper_add_route "$net/$mask" $class
    done 

}

function shaper_init
{
    check_db
    if_shaper_reset
    if_shaper_init
    ipt_init
    _ip route flush table $RTABLE
    
    local row
    row=$(db2 "select count${LB}class${RB} FROM $DBT;")
    
    if [ $row = 0 ]
    then
    shaper_add 127.255.255.100/31 $DEFAULT_SPEED 1 'Class for unlimited users'
    fi
}

function shaper_save_rules
{
    for dev in $dev_in $dev_out
	do
	_tc qdisc show dev $dev >$CFGDIR/$RULE_FILE.$dev
#	sed -i -e "s/\(qdisc\|class\)\(.*\)/$(escape_string ${ITC}) \1 add dev imq0 \2/" $CFGDIR/$RULE_FILE.$dev
	sed -i -e "s/\(qdisc\|class\)\(.*\)/\1 add dev $dev \2/" $CFGDIR/$RULE_FILE.$dev
	done
	
	_ip route save table 100 >$CFGDIR/"iproute.save"
}

function shaper_load_rules
{
    _ip route restore <$CFGDIR/"iproute.save"
    for dev in $dev_in $dev_out
	do
	tc -force -batch <$CFGDIR/$RULE_FILE.$dev
    done
    
    _ip route restore <$CFGDIR/"iproute.save"
}


case $1 in
	"show_shaper_db") show_shaper_db;;
	"shaper_add") shaper_add $2 $3 $4 $5;;
	"shaper_del") shaper_del $2;;
	"shaper_change") shaper_change $2 $3;;
	"shaper_init") shaper_init;;
	"shaper_load") shaper_load;;
	"shaper_save_rules") shaper_save_rules;;
	"shaper_load_rules") shaper_load_rules;;
esac
