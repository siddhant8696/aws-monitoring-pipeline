import boto3
import json
import os

def lambda_handler(event, context):
    ec2 = boto3.client('ec2')
    sns = boto3.client('sns')

    instance_id = event['detail']['configuration']['metrics'][0]['metricStat']['metric']['dimensions']['InstanceId']
    print(f"Remediation triggered for inmstance: {instance_id}")

    ec2.reboot_instances(InstanceIds=[instance_id])

    message = f"ALERT: Instance {instance_id} failed it status check.Automatic reboot has been triggered."

    sns.publish(
        TopicArn=os.environ['SNS_TOPIC_ARN'],
        Message=message,
        Subject="EC2 Auto-Remediation Triggered"
    )

    return {
        'statusCode': 200,
        'body': json.dumps(f'Remediation completed for {instance_id}')
    }