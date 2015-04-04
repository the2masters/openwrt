#!/bin/sh

get() {
    indirectvar="route_${1}_${2}"
    eval "echo \$${indirectvar}"
}

prefix() {
if [ -n "$2" ]; then
    echo "$1" "$2"
fi
}

# Function calculates number of bit in a netmask
#
mask2cidr() {
    nbits=0
    IFS=.
    for dec in $1 ; do
        case $dec in
            255) let nbits+=8;;
            254) let nbits+=7;;
            252) let nbits+=6;;
            248) let nbits+=5;;
            240) let nbits+=4;;
            224) let nbits+=3;;
            192) let nbits+=2;;
            128) let nbits+=1;;
            0);;
            *) echo "Error: $dec is not recognised"; exit 1
        esac
    done
    echo "$nbits"
}

n=1

while [ -n "$(get network $n)" ]; do
length=$(mask2cidr $(get netmask $n))
ip route add $(get network $n)/$(mask2cidr $(get netmask $n)) $(prefix via $(get gateway $n)) $(prefix metric $(get metric $n)) src $1
let n=$n+1
done

