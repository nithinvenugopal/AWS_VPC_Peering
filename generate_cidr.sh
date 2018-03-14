#!/bin/sh

region=$1
masterregion=$2
templatepath=$3
accountid=$4
tagname="testvpc"
stackname=`echo "Peerstack"$(date '+%d%m%Y%H%M%S')`

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
value=1
while [ $value -eq 1 ]
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
value=0
for x in $allvpccidr
do
        if [ $gen_vpc_cidr == $x ]
            then
            value=1
        fi
done
done

##### Generate Subnet CIDR #####

echo "Subnet CIDR are"
sc1=$c
declare -a subnetcidr=()
for i in `seq 1 $num_subnets`
do
    if [ $num_subnets -eq 2 ]; then add=8;e="21"; fi
    if [ $num_subnets -eq 3 ]; then add=4;e="22"; fi
    if [ $num_subnets -eq 4 ]; then add=4;e="22"; fi
    if [ $num_subnets -eq 5 ]; then add=2;e="23"; fi
    subnetcidr[$i]="$a.$b.$sc1.$d/$e"
    ((sc1=$sc1+$add))
    echo ${subnetcidr[$i]}
done

##### Generate Subnet CIDR END #####

# Create Cloud formation Stack

stackoutput=`aws cloudformation create-stack --stack-name $stackname --template-body $templatepath --parameters ParameterKey=PeerVPCcidr,ParameterValue=$gen_vpc_cidr ParameterKey=subnet1cidr,ParameterValue=${subnetcidr[1]} ParameterKey=subnet2cidr,ParameterValue=${subnetcidr[2]} ParameterKey=subnet3cidr,ParameterValue=${subnetcidr[3]} ParameterKey=subnet4cidr,ParameterValue=${subnetcidr[4]} ParameterKey=subnet5cidr,ParameterValue=${subnetcidr[5]}`

# Wait till the stack creation is completed
waitstatus=`aws cloudformation wait stack-create-complete --stack-name $stackname`

# Get VPC ID and Route table id from cloud formation output
stackoutput=`aws cloudformation describe-stacks --stack-name $stackname --query "Stacks[0].Outputs[*].OutputValue" --output text`

newvpcid=`echo $stackoutput | cut -d ' ' -f 2`
rtid=`echo $stackoutput | cut -d ' ' -f 1`

# Create VPC peering connection
peerid=`aws ec2 create-vpc-peering-connection --region $region --peer-owner-id $accountid --peer-vpc-id $master_vpc --vpc-id $newvpcid --peer-region $masterregion --output text --query "VpcPeeringConnection.VpcPeeringConnectionId"`

sleep 10

# Accept VPC connection from accepter region
acceptvpc=`aws ec2 accept-vpc-peering-connection --region $masterregion --vpc-peering-connection-id $peerid`

# Create route table in requester region
createroute=`aws ec2 create-route --region $region --route-table-id $rtid --destination-cidr-block $master_vpc_cidr --vpc-peering-connection-id $peerid`

# Get route table association id of default route table in the requester region
rtassocid=`aws ec2 describe-route-tables --region $region --filters Name=vpc-id,Values=$newvpcid Name=association.main,Values=true --query "RouteTables[0].Associations[0].RouteTableAssociationId" --output text`

# Set the new route table as main table
replaceroutemain=`aws ec2 replace-route-table-association --region $region --association-id $rtassocid --route-table-id $rtid`

# Create internet gateway in accepter region
igwid=`aws ec2 describe-internet-gateways --region $region --filters Name=attachment.vpc-id,Values=$newvpcid --query "InternetGateways[*].InternetGatewayId" --output text`

# Create route to the internet gateway
createrouterq=`aws ec2 create-route --route-table-id $rtid --destination-cidr-block "0.0.0.0/0" --gateway-id $igwid`

# Create security group in the requester region and create ingress to office IP
sgid=`aws ec2 create-security-group --description "Security group of the new VPC" --group-name "Main SG" --vpc-id $newvpcid --output text`
authsg=`aws ec2 authorize-security-group-ingress --region $region --group-id $sgid --protocol all --cidr $intcidr`

# Get route table id from the accepter region and create route to the vpc peer
masterrtid=`aws ec2 describe-route-tables --region $masterregion --filters Name=vpc-id,Values=$master_vpc --query "RouteTables[*].Associations[0].RouteTableId" --output text`
createrouteacc=`aws ec2 create-route --region $masterregion --route-table-id $masterrtid --destination-cidr-block $gen_vpc_cidr --vpc-peering-connection-id $peerid`

# Get security group id and create ingress from the peered vpc cidr range in accepter region
mastersgid=`aws ec2 describe-security-groups --region $masterregion --filters Name=vpc-id,Values=$master_vpc --query "SecurityGroups[*].GroupId" --output text`
authsg2=`aws ec2 authorize-security-group-ingress --region $masterregion --group-id $mastersgid --protocol all --cidr $gen_vpc_cidr`

# Get all the output for teardown
echo $region $masterregion $masterrtid $gen_vpc_cidr $mastersgid $peerid $sgid $newvpcid $rtid $stackname

