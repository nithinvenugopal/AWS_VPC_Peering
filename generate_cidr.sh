#!/bin/sh

region=$1
masterregion=$2
templatepath=$3
accountid=$4
tagname="testvpc"
stackname="testvpcstack"

## Get VPC cidr of all regions
for allregion in `aws ec2 describe-regions --output text | cut -f3`
do
	cmd=`aws ec2 describe-vpcs --region $allregion --output text --query "Vpcs[*].CidrBlock"`
	allvpccidr="$allvpccidr $cmd"    
done

cmd2=`aws ec2 describe-vpcs --region $masterregion --filters Name=tag-value,Values=$tagname --output text --query "Vpcs[0].[VpcId,CidrBlock]"`
master_vpc=`echo $cmd2 | cut -d ' ' -f 1`
master_vpc_cidr=`echo $cmd2 | cut -d ' ' -f 2` 

num_az=`aws ec2 describe-availability-zones --region $region --output text --query "AvailabilityZones[*].ZoneName" | wc -w`

num_subnets=$num_az

##### Generate VPC CIDR #####

while true
do
case $(( RANDOM % 3 )) in
    0)
        a=10
        ;;
    1)
        a=172
        ;;
    2)
        a=192
        ;;
esac
if [ $a -eq 192 ]
then
b=168
c=1
while [ $(($c % 16)) -ne 0 ]
do
        c=$((RANDOM%255))
done
d=0
fi
if [ $a -eq 172 ]
then
b=$[ ( $RANDOM % 30 )  + 16 ]   # 172.31 already taken by default VPC
c=1
while [ $(($c % 16)) -ne 0 ]
do
        c=$((RANDOM%255))
done
d=0
fi
if [ $a -eq 10 ]
then
b=$[ ( $RANDOM % 255 ) ]
c=1
while [ $(($c % 16)) -ne 0 ]
do
        c=$((RANDOM%255))
done
d=0
fi

##### Generate VPC CIDR END #####

gen_vpc_cidr="$a.$b.$c.$d/20"
echo $gen_vpc_cidr

for x in $allvpccidr
do
        if [ $gen_vpc_cidr == $x ]
        then
        continue
        fi
done
break
done

##### Generate Subnet CIDR #####

echo "Subnet CIDR are"

if [ $num_subnets -eq 2 ]
then
sc1=$c
((sc2=$sc1+8))
subnet1cidr="$a.$b.$sc1.$d/21"
subnet2cidr="$a.$b.$sc2.$d/21"
fi
if [ $num_subnets -eq 3 ]
then
sc1=$c
((sc2=$sc1+4))
((sc3=$sc2+4))
subnet1cidr="$a.$b.$sc1.$d/22"
subnet2cidr="$a.$b.$sc2.$d/22"
subnet3cidr="$a.$b.$sc3.$d/22"
fi
if [ $num_subnets -eq 4 ]
then
sc1=$c
((sc2=$sc1+4))
((sc3=$sc2+4))
((sc4=$sc3+4))
subnet1cidr="$a.$b.$sc1.$d/22"
subnet2cidr="$a.$b.$sc2.$d/22"
subnet3cidr="$a.$b.$sc3.$d/22"
subnet4cidr="$a.$b.$sc4.$d/22"
fi
if [ $num_subnets -eq 5 ]
then
sc1=$c
((sc2=$sc1+2))
((sc3=$sc2+2))
((sc4=$sc3+2))
((sc5=$sc4+2))
subnet1cidr="$a.$b.$sc1.$d/23"
subnet2cidr="$a.$b.$sc2.$d/23"
subnet3cidr="$a.$b.$sc3.$d/23"
subnet4cidr="$a.$b.$sc4.$d/23"
subnet5cidr="$a.$b.$sc5.$d/23"
fi

##### Generate Subnet CIDR #####

stackoutput=`aws cloudformation create-stack --stack-name $stackname --template-body $templatepath --parameters ParameterKey=PeerVPCcidr,ParameterValue=$gen_vpc_cidr ParameterKey=subnet1cidr,ParameterValue=$subnet1cidr ParameterKey=subnet2cidr,ParameterValue=$subnet2cidr ParameterKey=subnet3cidr,ParameterValue=$subnet3cidr ParameterKey=subnet4cidr,ParameterValue=$subnet4cidr ParameterKey=subnet5cidr,ParameterValue=$subnet5cidr`

#Wait till the stack creation is completed
waitstatus=`aws cloudformation wait stack-create-complete --stack-name $stackname`

stackoutput=`aws cloudformation describe-stacks --stack-name $stackname --query "Stacks[0].Outputs[*].OutputValue" --output text`

newvpcid=`echo $stackoutput | cut -d ' ' -f 2`
rtid=`echo $stackoutput | cut -d ' ' -f 1`

peerid=`aws ec2 create-vpc-peering-connection --region $region --peer-owner-id $accountid --peer-vpc-id $master_vpc --vpc-id $newvpcid --peer-region $masterregion --output text --query "VpcPeeringConnection.VpcPeeringConnectionId"`

sleep 10

acceptvpc=`aws ec2 accept-vpc-peering-connection --region $masterregion --vpc-peering-connection-id $peerid`

createroute=`aws ec2 create-route --route-table-id $rtid --destination-cidr-block $master_vpc_cidr --vpc-peering-connection-id $peerid`

rtassocid=`aws ec2 describe-route-tables --filters Name=vpc-id,Values=$newvpcid Name=association.main,Values=true --query "RouteTables[0].Associations[0].RouteTableAssociationId" --output text`

replaceroutemain=`aws ec2 replace-route-table-association --association-id $rtassocid --route-table-id $rtid`

igwid=`aws ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values=$newvpcid --query "InternetGateways[*].InternetGatewayId" --output text`

createrouterq=`aws ec2 create-route --route-table-id $rtid --destination-cidr-block "0.0.0.0/0" --gateway-id $igwid`

sgid=`aws ec2 create-security-group --description "Security group of the new VPC" --group-name "Main SG" --vpc-id $newvpcid --output text`

authsg=`aws ec2 authorize-security-group-ingress --region $region --group-id $sgid --protocol all --cidr $ip`

masterrtid=`aws ec2 describe-route-tables --region $masterregion --filters Name=vpc-id,Values=$master_vpc --query "RouteTables[*].Associations[0].RouteTableId" --output text`

createrouteacc=`aws ec2 create-route --region $masterregion --route-table-id $masterrtid --destination-cidr-block $gen_vpc_cidr --vpc-peering-connection-id $peerid`

mastersgid=`aws ec2 describe-security-groups --region $masterregion --filters Name=vpc-id,Values=$master_vpc --query "SecurityGroups[*].GroupId" --output text`

authsg2=`aws ec2 authorize-security-group-ingress --region $masterregion --group-id $mastersgid --protocol all --cidr $gen_vpc_cidr`

echo $region $masterregion $masterrtid $gen_vpc_cidr $mastersgid $peerid $sgid $newvpcid $rtid
