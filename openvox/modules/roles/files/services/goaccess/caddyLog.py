#!/usr/bin/python3

""" ***********************************************************************************

Takes Caddy log data (in JSON format) as input (provided in the form of either an 
existing Caddy log file, or alternatively streamed over a network using TCP/IP sockets)
and converts it into a format suitable for analysis by goAccess (https://goaccess.io/).

To use the output file, goaccess must be run with the log-format specified as shown
below

    goaccess access.goaccess.log --log-format="%d %t %v %h %m %U %H %s %b %T %R %u" \
                                 --date-format=%F --time-format=%H:%M:%S -o access.html

*********************************************************************************** """

import sys, signal, getopt, socket, json, os
from datetime import datetime
from time import sleep

networkAddress = ''
inputJSONfilename = ''
timeInterval = 0
outputGoAccessFilename = ''
outputJSONfilename = ''

def convertJSONtoGoAccess (JSONdata):
    ts = str(datetime.fromtimestamp(JSONdata['ts']))
    date = ts[0:10]
    time = ts[11:19]
    virtualHost = JSONdata['request']['host']

    # Caddy's remote_ip is already IP-only, no port stripping needed
    # But sometimes it might be remote_addr with port, so let's be safe
    if 'remote_ip' in JSONdata['request']:
        host = JSONdata['request']['remote_ip']
    else:
        host = JSONdata['request']['remote_addr']
        if ':' in host:
            host = host[0:host.rindex(':')]
        if (len(host) > 0 and host[0] == '['):
            host = host[1:host.rindex(']')]

    method = JSONdata['request']['method']
    uri = JSONdata['request']['uri']
    proto = JSONdata['request']['proto']

    status = str( JSONdata['status'] )
    size = str( JSONdata.get('size', 0) )
    latency = str( JSONdata['duration'] )

    if "Referer" in JSONdata['request']['headers'].keys():
        referer = JSONdata['request']['headers']['Referer'][0]
    else:
        referer = 'unknown'
    
    if "User-Agent" in JSONdata['request']['headers'].keys():
        user_agent = '"'+JSONdata['request']['headers']['User-Agent'][0]+'"'
    else:
        user_agent = '""'

    goAccessData = date+' '+time+' '+virtualHost+' '+host+' '+method+' '+uri+' '+proto+' '+status+' '+size+' '+latency+' '+referer+' '+user_agent
    return goAccessData

def main():
    global networkAddress
    global inputJSONfilename
    global timeInterval
    global outputGoAccessFilename
    global outputJSONfilename

    print()
    print('{} - INITIALISING: caddyLog.py (Caddy/GoAccess data logger & converter)'.format(datetime.now()))

    if (inputJSONfilename):
        try:
            g = open(outputGoAccessFilename, 'w')
        except IOError:
            print()
            print('{} - ERROR: Output file "{}" error'.format(datetime.now(), outputGoAccessFilename))
            sys.exit(2)

        try:
            j = open(inputJSONfilename)
        except FileNotFoundError:
            print()
            print('{} - ERROR: Input file "{}" not found'.format(datetime.now(), inputJSONfilename))
            g.close()
            sys.exit(2)

        print('{} - processing JSON input file: {}'.format(datetime.now(), inputJSONfilename))
        totalLogCount = 0
        batchLogCount = 0
        current_inode = os.fstat(j.fileno()).st_ino
        try:
            while True:
                line = j.readline()
                if (line != ""):
                    try:
                        JSONdata = json.loads(line)
                        # Caddy writes multiple loggers into the same access.log
                        # (http.log.error.*, http.acme_client, tls.cache.maintenance,
                        # ...) alongside the real http.log.access.* entries. Those
                        # have a completely different shape (no request/size/status)
                        # and were never meant to reach goaccess - skip quietly
                        # rather than treating a routine ACME renewal or error log
                        # line as a malformed access record.
                        if not JSONdata.get('logger', '').startswith('http.log.access'):
                            continue
                        goAccessData = convertJSONtoGoAccess(JSONdata)
                        g.write(goAccessData+'\n')
                        totalLogCount += 1
                        batchLogCount += 1
                    except json.JSONDecodeError:
                        continue
                    except Exception as e:
                        print(f"Error processing line: {e}")
                        continue
                elif (timeInterval > 0):
                    g.flush()
                    if (batchLogCount):
                        print('{} - {} log entries written to {}'.format(datetime.now(), str(batchLogCount), outputGoAccessFilename))
                        batchLogCount = 0
                    # Detect log rotation: if the file at the path has a different
                    # inode, the log was rotated — reopen the new file.
                    try:
                        if os.stat(inputJSONfilename).st_ino != current_inode:
                            print('{} - log rotation detected, reopening {}'.format(datetime.now(), inputJSONfilename))
                            j.close()
                            j = open(inputJSONfilename)
                            current_inode = os.fstat(j.fileno()).st_ino
                            continue
                    except FileNotFoundError:
                        pass
                    print('{} - sleeping for {} seconds before checking for additional log entries'.format(datetime.now(), str(timeInterval)))
                    sleep(timeInterval)
                elif (timeInterval == 0):
                    print('{} - TOTAL: {} log entries written to {}'.format(datetime.now(), str(totalLogCount), outputGoAccessFilename))
                    print()
                    g.flush()
                    break
        finally:
            j.close()
            g.close()

def signal_handler(signal, frame):
    print()
    print('{} - Terminating . . . '.format(datetime.now()))
    sys.exit(0)

if __name__ == "__main__":
    signal.signal(signal.SIGINT, signal_handler)
    
    # Simple argument parsing for our use case
    inputJSONfilename = sys.argv[2] if len(sys.argv) > 2 and sys.argv[1] == '-i' else ''
    timeInterval = int(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[3] == '-t' else 0
    outputGoAccessFilename = sys.argv[6] if len(sys.argv) > 6 and sys.argv[5] == '-g' else ''
    
    main()
