# Dualtone Communications Ltd - Sensu Checks

## Checks designed and implemented on Dualtone Systems for Internal Use and Customer Systems and Proxmox Hosts (Debian 8-11 Tested).

### These are the only tested systems, may work on others, outside of this scope.

## Installation
### Step 1:
Please check you're on a tested OS [Debian 8, Debian 9, Debian 10 or Debian 11] - 

```cat /etc/os-release```

### Step 2:
Clone this repo using your own key or user and pass -

```mkdir /usr/local/dualtone; git clone https://<yourlogin>@github.com/dualtonecomms/sensu-checks.git /usr/local/dualtone/sensu-checks && chmod -R +x /usr/local/dualtone/sensu-checks/```

### Step 3a:
With the repo cloned, you can now install the Nagios Perl script libraries, used for the fs_cli checks (If apt shows 0 to remove, you should be able to press 'Y' at install) - 

```apt-get install sudo make libperl-dev libparams-validate-perl libmath-calc-units-perl libclass-accessor-perl libconfig-tiny-perl git && cd /tmp && git clone https://github.com/nagios-plugins/nagios-plugin-perl.git && cd nagios-plugin-perl && perl Makefile.PL && make && make test && make install && chmod 775 -R /usr/local/freeswitch/```

### Step 3b:
Apt was broken on most machines I ran this on, so here is a one-liner to fix and bypass the old repo's and to add the Key that was showing invalid - 

```sed -i 's/deb http:\/\/packages.irontec.com\/debian jessie main/#deb http:\/\/packages.irontec.com\/debian jessie main/g' /etc/apt/sources.list && sed -i 's/deb http:\/\/files.freeswitch.org\/repo\/deb\/freeswitch-1.6\/ jessie main/#deb http:\/\/files.freeswitch.org\/repo\/deb\/freeswitch-1.6\/ jessie main/g' /etc/apt/sources.list.d/freeswitch.list && sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys AA8E81B4331F7F50 && apt update```

### Step 4:
(If you followed the apt-prep above, please re-run step 3a then come back here)
Now you should be able to install the sensu-go-agent as well as the Dualtone agent configuration for Sensu - 

```curl -s https://packagecloud.io/install/repositories/sensu/stable/script.deb.sh | sudo bash || cat /etc/os-release && sudo apt-get install sensu-go-agent && wget https://dualtone-public.s3.eu-west-2.amazonaws.com/agent.yml -O /etc/sensu/agent.yml && service sensu-agent start || service sensu-agent status && service sensu-agent status```

### Complete

## For Updates

Please use this one-liner to cd to the right location and git pull - 

```cd /usr/local/dualtone/sensu-checks/ && git pull```
