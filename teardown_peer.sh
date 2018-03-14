#!/bin/sh

region=$1
masterregion=$2
masterrtid=$3
gen_vpc_cidr=$4
mastersgid=$5
peerid=$6
sgid=$7
newvpcid=$8
rtid=$9

SGname="Main SG"
stackname="testvpcstack"

# Master

# Delete Route from route table

aws ec2 delete-route --region $masterregion --route-table-id $masterrtid --destination-cidr-block $gen_vpc_cidr

# Delete Security Group entry from SG

aws ec2 revoke-security-group-ingress --region $masterregion --group-id $mastersgid --cidr $gen_vpc_cidr --protocol all

# Requester

# Delete Peering connection

aws ec2 delete-vpc-peering-connection --region $region --vpc-peering-connection-id $peerid

# Delete Security Group

aws ec2 delete-security-group --region $region --group-id $sgid

# Change Main route table and delete route table

rtassocid=`aws ec2 describe-route-tables --region $region --filters Name=vpc-id,Values=$newvpcid Name=association.main,Values=true --query "RouteTables[0].Associations[0].RouteTableAssociationId" --output text`

rtiddefault=""
for rts in `aws ec2 describe-route-tables --region $region --filters Name=vpc-id,Values=$newvpcid --query RouteTables[*].RouteTableId --output text`
do
	if [ "$rts" != "$rtid" ]
		then
		rtiddefault=$rts
	fi    
done


aws ec2 replace-route-table-association --region $region --association-id $rtassocid --route-table-id $rtiddefault

aws ec2 delete-route-table --region $region --route-table-id $rtid

# Delete cloudformation stack

aws cloudformation delete-stack --region $region --stack-name $stackname

