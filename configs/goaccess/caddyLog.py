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

import sys, signal, getopt, socket, json
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
    host = JSONdata['request']['remote_ip']

    method = JSONdata['request']['method']
    uri = JSONdata['request']['uri']
    proto = JSONdata['request']['proto']

    status = str( JSONdata['status'] )
    size = str( JSONdata['size'] )
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
            with open(outputGoAccessFilename, 'w') as g:
                totalLogCount = 0
                try:
                    with open(inputJSONfilename) as j:
                        print('{} - processing JSON input file: {}'.format(datetime.now(), inputJSONfilename))
                        batchLogCount = 0
                        while True:
                            line = j.readline()
                            if (line != ""):
                                try:
                                    JSONdata = json.loads(line)
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
                                print('{} - sleeping for {} seconds before checking for additional log entries'.format(datetime.now(), str(timeInterval)))
                                sleep(timeInterval)
                            elif (timeInterval == 0):
                                print('{} - TOTAL: {} log entries written to {}'.format(datetime.now(), str(totalLogCount), outputGoAccessFilename))
                                print()
                                batchLogCount = 0
                                g.flush()
                                break
                except FileNotFoundError:
                    print()
                    print('{} - ERROR: Input file "{}" not found'.format(datetime.now(), inputJSONfilename))
                    sys.exit(2)
        except IOError:
            print()
            print('{} - ERROR: Output file "{}" error'.format(datetime.now(), outputGoAccessFilename))
            sys.exit(2)

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
