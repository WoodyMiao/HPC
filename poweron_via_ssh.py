#!/usr/bin/python
import os
import sys


# To reset passward, ssh to the host and enter the two commands:
# modprobe ipmi_devintf
# ipmitool -I open user set password 2 NEW_PASSWORD


ip = {
    'pan01': '10.10.1.101',
    'pan02': '10.10.1.104',
    'gpu01': '10.10.1.91',
    'Pstor7100-01': '10.10.1.11',
    'Pstor7100-02': '10.10.1.12',
    'Pstor7100-03': '10.10.1.13',
}

user = {
    'pan01': 'ADMIN',
    'pan02': 'ADMIN',
    'gpu01': 'ADMIN',
    'Pstor7100-01': 'ADMIN',
    'Pstor7100-02': 'ADMIN',
    'Pstor7100-03': 'ADMIN',
}
    
passwd = {
    'pan01': 'ADMIN',
    'pan02': 'ADMIN',
    'gpu01': 'ADMIN',
    'Pstor7100-01': 'ADMIN',
    'Pstor7100-02': 'ADMIN',
    'Pstor7100-03': 'ADMIN',
}

action = {
    'show': 'show /system1/pwrmgtsvc1',
    'poweron': 'start /system1/pwrmgtsvc1',
    'poweroff': 'end /system1/pwrmgtsvc1',
    'reboot': 'reset /system1/pwrmgtsvc1',
}


usage = '\nUsage: ' + sys.argv[0] + ' <print|do> <gpu01|pan01|pan02|Pstor7100-01|Pstor7100-02|Pstor7100-03> <show|poweron|poweroff|reboot>\n'
if (len(sys.argv) < 4) or (sys.argv[2] not in user) or (sys.argv[3] not in action):
    print usage
    sys.exit(1)


node = sys.argv[2]
cmd = 'echo "' + action[sys.argv[3]] + '"' + ' | sshpass -p ' + passwd[node] + ' ssh -T ' + user[node] + '@' + ip[node]
if sys.argv[1] == 'print':
    print cmd
elif sys.argv[1] == 'do':
    os.system(cmd)
else:
    print usage
    sys.exit(1)
