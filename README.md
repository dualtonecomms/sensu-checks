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

## HTTP and SIP checks

The HTTP check requires `curl`, `awk`, `mktemp` and `cmp`. Existing `-w`, `-c`, `-u` and `-nocert` arguments still work. It measures one HTTP request per attempt, including redirects, and requires a successful HTTP status and a non-empty body. Certificate validation remains enabled unless `-nocert` is supplied.

Slow responses and transient connection failures get one retry after 200ms. HTTP error statuses, certificate validation failures and unexpected response bodies fail immediately. The output records the first failure when a retry was needed. Normal checks make one request instead of downloading the URL twice.

For an endpoint that should return exactly `OK`, add `-e OK`:

```sh
/usr/local/dualtone/sensu-checks/http/check_website_response.sh -w 2500 -c 5000 -u https://api.teleflow.app/health -e OK
```

`-e` compares the entire body, including whitespace. Set the Sensu execution timeout to at least **15 seconds** for the thresholds above. For other critical thresholds, allow two attempts of `(critical milliseconds / 1000) + 1` seconds, plus retry and process-start time.

The SIP check keeps its existing two attempts and default 3000ms response timeout. Provisional `1xx` responses do not end the check or extend its deadline. A valid reply to the first attempt is accepted while the retry is running. Final `3xx` responses remain warnings, and `4xx`–`6xx` responses remain failures; those replies are not retried away. Invalid URI, port or timeout arguments return UNKNOWN, and local socket errors return a failure with the error details.

Allow at least **10 seconds** in Sensu for the default SIP settings. If you override the response timeout with the fourth argument or `SIP_OPTIONS_TIMEOUT_MS`, allow both attempts plus process-start time.

## For Updates

Please use this one-liner to cd to the right location and git pull - 

```cd /usr/local/dualtone/sensu-checks/ && git pull```
