
#!/bin/bash

# ----------------------------------------------------------------------------------------
# GENERAL INFORMATION
# ----------------------------------------------------------------------------------------
#
# Written by Andrew J Freyer
# GNU General Public License
# http://github.com/andrewjfreyer/monitor
#
# Credits to:
#		Radius Networks iBeacon Script
#			• http://developer.radiusnetworks.com/ibeacon/idk/ibeacon_scan
#
#		Reely Active advlib
#			• https://github.com/reelyactive/advlib
#
#                        _ _             
#                       (_) |            
#  _ __ ___   ___  _ __  _| |_ ___  _ __ 
# | '_ ` _ \ / _ \| '_ \| | __/ _ \| '__|
# | | | | | | (_) | | | | | || (_) | |   
# |_| |_| |_|\___/|_| |_|_|\__\___/|_|
#
# ----------------------------------------------------------------------------------------

#VERSION NUMBER
version=0.1.342


# ----------------------------------------------------------------------------------------
# KILL OTHER SCRIPTS RUNNING
# ----------------------------------------------------------------------------------------
for pid in $(pidof -x $(basename $0)); do
    if [ $pid != $$ ]; then
        kill -9 $pid
    fi 
done


#FOR DEBUGGING, BE SURE THAT PRESENCE IS ALSO KILLED, IF RUNNING
for pid in $(pidof -x "presence.sh"); do
    if [ $pid != $$ ]; then
        kill -9 $pid
    fi 
done

# ----------------------------------------------------------------------------------------
# CLEANUP ROUTINE 
# ----------------------------------------------------------------------------------------
clean() {
	#CLEANUP FOR TRAP
	while read line; do 
		`sudo kill $line` &>/dev/null
	done < <(ps ax | grep monitor.sh | awk '{print $1}')

	#REMOVE PIPES
	sudo rm main_pipe &>/dev/null
	sudo rm log_pipe &>/dev/null

	#MESSAGE
	echo 'Exited.'
}

trap "clean" EXIT

# ----------------------------------------------------------------------------------------
# SOURCE FILES 
# ----------------------------------------------------------------------------------------

source './support/debug'
source './support/setup'
source './support/data'
source './support/btle'
source './support/mqtt'
source './support/time'

# ----------------------------------------------------------------------------------------
# BEHAVIOR PREFERENCES
# ----------------------------------------------------------------------------------------

#DETERMINE WHETHER SHOULD PRIME A DEVICE BEFORE NAME-SCANNING
PREF_SHOULD_PRIME=false

#DETERMINE DELAY BETWEEN SCANS OF DEVICES 
PREF_INTERSCAN_DELAY=3

#DETERMINE HOW OFTEN TO CHECK FOR AN EXPIRED DEVICE OR FOR A DEPARTED OR ARRIVED DEVICE
PREF_CLOCK_INTERVAL=120

#DETERMINE NOW OFTEN TO REFRESH DATABASES TO REMOVE EXPIRED DEVICES
PREF_DATABASE_REFRESH_INTERVAL=30

#MAX RETRY ATTEMPTS FOR ARRIVAL
PREF_ARRIVAL_SCAN_ATTEMPTS=2

#MAX RETRY ATTEMPTS FOR DEPART
PREF_DEPART_SCAN_ATTEMPTS=4

# ----------------------------------------------------------------------------------------
# DEFINE VALUES AND VARIABLES
# ----------------------------------------------------------------------------------------

#CYCLE BLUETOOTH INTERFACE 
sudo hciconfig hci0 down && sudo hciconfig hci0 up

#SETUP MAIN PIPE
sudo rm main_pipe &>/dev/null
mkfifo main_pipe

#SETUP LOG PIPE
sudo rm log_pipe &>/dev/null
mkfifo log_pipe

#DEFINE DEVICE TRACKING VARS
declare -A static_device_log
declare -A random_device_log
declare -A named_device_log

#STATIC DEVICE ASSOCIATIVE ARRAYS
declare -A known_static_device_log
declare -A known_static_device_scan_log
declare -A known_static_device_name

#LAST TIME THIS 
random_device_last_update=$(date +%s)
scan_pid=""
scan_type=""

#DEFINE PERFORMANCE TRACKING/IMRROVEMENT VARS
declare -A expired_device_log
declare -A device_expiration_biases

#SCAN VARIABLES
last_arrival_scan=$(date +%s)
last_depart_scan=$(date +%s)

# ----------------------------------------------------------------------------------------
# POPULATE THE ASSOCIATIVE ARRAYS THAT INCLUDE INFORMATION ABOUT THE STATIC DEVICES
# WE WANT TO TRACK
# ----------------------------------------------------------------------------------------

#LOAD PUBLIC ADDRESSES TO SCAN INTO ARRAY, IGNORING COMMENTS
known_static_addresses=($(cat "$PUB_CONFIG" | sed 's/#.\{0,\}//g' | awk '{print $1}' | grep -oiE "([0-9a-f]{2}:){5}[0-9a-f]{2}" ))

#POPULATE KNOWN DEVICE ADDRESS
for addr in ${known_static_addresses[@]}; do 
	#WAS THERE A NAME HERE?
	known_name=$(grep "$addr" "$PUB_CONFIG" | tr "\t" " " | sed 's/  */ /g;s/#.\{0,\}//g' | sed "s/$addr //g;s/  */ /g" )

	#IF WE FOUND A NAME, RECORD IT
	[ ! -z "$known_name" ] && known_static_device_name[$addr]="$known_name"
done

#LOOP SCAN VARIABLES
device_count=${#known_static_addresses[@]}

# ----------------------------------------------------------------------------------------
# ASSEMBLE ARRIVAL SCAN LIST
# ----------------------------------------------------------------------------------------

scannable_devices_with_state () {
	#DEFINE LOCAL VARS
	local return_list=""
	local timestamp=$(date +%s)

	#IF WE ARE SCANNING FOR ARRIVALS, THIS VALUE SHOULD BE 
	#0; IF WE ARE SCANNING FOR DEPARTURES, THIS VALUE SHOULD
	#BE 1.
	local scan_state="$1"

	#SCAN ALL? SET THE SCAN STATE TO [X]
	[ -z "$scan_state" ] && scan_state=2
			 	
	#ITERATE THROUGH THE KNOWN DEVICES 
	for known_addr in "${known_static_addresses[@]}"; do 
		
		#GET STATE; ONLY SCAN FOR DEVICES WITH SPECIFIC STATE
		local this_state="${known_static_device_log[$known_addr]}"

		#IF WE HAVE NEVER SCANNED THIS DEVICE BEFORE, WE MARK AS 
		#SCAN STATE [X]; THIS ALLOWS A FIRST SCAN TO PROGRESS TO 
		#COMPLETION FOR ALL DEVICES
		[ -z "$this_state" ] && this_state=3

		#FIND LAST TIME THIS DEVICE WAS SCANNED
		local last_scan="${known_static_device_scan_log[$known_addr]}"
		local time_diff=$((timestamp - last_scan))

		#SCAN IF DEVICE HAS NOT BEEN SCANNED 
		#WITHIN LAST [X] SECONDS
		if [ "$time_diff" -gt "5" ]; then 

			#TEST IF THIS DEVICE MATCHES THE TARGET SCAN STATE
			if [ "$this_state" == "$scan_state" ]; then 
				#ASSEMBLE LIST OF DEVICES TO SCAN
				return_list=$(echo "$return_list $this_state$known_addr")

			elif [ "$this_state" == "2" ] || [ "$this_state" == "3" ]; then

				#SCAN FOR ALL DEVICES THAT HAVEN'T BEEN RECENTLY SCANNED; 
				#PRESUME DEVICE IS ABSENT
				return_list=$(echo "$return_list 0$known_addr")
			fi 
		fi 
	done
 
	#RETURN LIST, CLEANING FOR EXCESS SPACES OR STARTING WITH SPACES
	return_list=$(echo "$return_list" | sed 's/^ //g;s/ $//g;s/  */ /g')

	#RETURN THE LIST
	echo "$return_list"
}

# ----------------------------------------------------------------------------------------
# SCAN FOR ARRIVED DEVICE
#
# FOR AN ARRIVAL SCAN, WE DO NOT NECESSARILY NEED TO VERIFY A HIGH NUBMER OF TIMES
# THAT A DEVICE HAS ACTUALLY ARRIVED. 
# ----------------------------------------------------------------------------------------

perform_scan () {
	#IF WE DO NOT RECEIVE A SCAN LIST, THEN RETURN 0
	if [ -z "$1" ]; then 
		#NEED TO WAIT SO THAT THE PID CAN ACTUALLY RETURN CORRECTLY
		sleep 1

		#LOG IMMEDIATE RETURN
		log "${GREEN}[CMD-SCAN]	${GREEN}**** Rejected scan. No devices in requested state.  **** ${NC}"
	 	return 0
	fi

	#REPEAT THROUGH ALL DEVICES THREE TIMES, THEN RETURN 
	local repetitions=2
	[ ! -z "$2" ] && repetitions="$2"
	[ "$repetitions" -lt "1" ] && repetitions=1

	#INTERATION VARIABLES
	local devices="$1"
	local devices_next="$devices"
	local scan_start=""
	local scan_duration=""
	
	#LOG START OF DEVICE SCAN 
	log "${GREEN}[CMD-SCAN]	${GREEN}**** Started scan. [x$repetitions] **** ${NC}"

	#ITERATE THROUGH THE KNOWN DEVICES 	
	for repetition in $(seq 1 $repetitions); do

		#SET DEVICES
		devices="$devices_next"

		#ITERATE THROUGH THESE 
		for device_data in $devices; do 

			#SUBDIVIDE ADDR OBJECT
			local known_addr="${device_data:1}"
			local previous_state="${device_data:0:1}"

			#IF THE PREVIOUS STATE IF 0 THEN WE WILL RETURN IMMEDIATELY IF A DEVICE IS FOUND

			#SCAN TYPE
			local transition_type="arrived"
			[ "$previous_state" == "1" ] && transition_type="departed"

			#IN CASE WE HAVE A BLANK ADDRESS, FOR WHATEVER REASON
			[ -z "$known_addr" ] && continue

			#DETERMINE START OF SCAN
			scan_start="$(date +%s)"

			#GET NAME USING HCITOOL AND RAW COMMAND;
			#THIS APPEARS TO HAVE THE EFFECT OF PRIMING THE DEVICE THAT WE ARE INQUIRING
			#WHEN THE DEVICE IS PRESENT
			if [ "$PREF_SHOULD_PRIME" == true ]; then 
				hcitool cmd 0x01 0x0019 $(echo "$known_addr" | awk -F ":" '{print "0x"$6" 0x"$5" 0x"$4" 0x"$3" 0x"$2" 0x"$1}') 0x02 0x00 0x00 0x00 &>/dev/null

				#DELAY BETWEN SCAN
				sleep 2
			fi 

			#DEBUG LOGGING
			log "${GREEN}[CMD-SCAN]	${GREEN}(No. $repetition)${NC} $known_addr $transition_type? ${NC}"

			local name_raw=$(hcitool name "$known_addr")
			local name=$(echo "$name_raw" | grep -ivE 'input/output error|invalid device|invalid|error')

			#COLLECT STATISTICS ABOUT THE SCAN 
			local scan_end="$(date +%s)"
			local scan_duration=$((scan_end - scan_start))

			#MARK THE ADDRESS AS SCANNED SO THAT IT CAN BE LOGGED ON THE MAIN PIPE
			echo "SCAN$known_addr" > main_pipe & 

			#IF STATUS CHANGES TO PRESENT FROM NOT PRESENT, REMOVE FROM VERIFICATIONS
			if [ ! -z "$name" ] && [ "$previous_state" == "0" ]; then 

				#PUSH TO MAIN POPE
				echo "NAME$known_addr|$name" > main_pipe & 

				#REMOVE FROM SCAN
				devices_next=$(echo "$devices_next" | sed "s/$device_data//g;s/  */ /g")

			elif [ ! -z "$name" ] && [ "$previous_state" == "3" ]; then 
				#HERE, WE HAVE FOUND A DEVICE FOR THE FIRST TIME
				devices_next=$(echo "$devices_next" | sed "s/$device_data//g;s/  */ /g")

			elif [ ! -z "$name" ] && [ "$previous_state" == "1" ]; then 
				#THIS DEVICE IS STILL PRESENT; REMOVE FROM VERIFICATIONS
				devices_next=$(echo "$devices_next" | sed "s/$device_data//g;s/  */ /g")
			fi 

			#IF WE HAVE NO MORE DEVICES TO SCAN, IMMEDIATELY RETURN
			[ -z "$devices_next" ] && break

			#TO PREVENT HARDWARE PROBLEMS
			if [ "$scan_duration" -lt "$PREF_INTERSCAN_DELAY" ]; then 
				local adjusted_delay="$((PREF_INTERSCAN_DELAY - scan_duration))"

				if [ "$adjusted_delay" -gt "0" ]; then 
					sleep "$adjusted_delay"
				else
					#DEFAULT MINIMUM SLEEP
					sleep 2
				fi 
			else
				#DEFAULT MINIMUM SLEEP
				sleep 2
			fi 
		done

		#ARE WE DONE WITH ALL DEVICES? 
		[ -z "$devices_next" ] && break
	done 

	#ANYHTING LEFT IN THE DEVICES GROUP IS NOT PRESENT
	for device_data in $devices_next; do 
		local known_addr="${device_data:1}"
		echo "NAME$known_addr|" > main_pipe & 
	done

	#GROUP SCAN FINISHED
	log "${GREEN}[CMD-SCAN]	${GREEN}**** Completed scan. **** ${NC}"

	#DELAY BEFORE CLEARNING THE MAIN PIPE
	sleep 1

	#SET DONE TO MAIN PIPE
	echo "DONE" > main_pipe
}

# ----------------------------------------------------------------------------------------
# SCAN TYPES
# ----------------------------------------------------------------------------------------

perform_departure_scan () {

	log "${GREEN}[REQUEST]	${NC}Departure scan requested."

	#SET SCAN TYPE
 	local depart_list=$(scannable_devices_with_state 1)

 	#LOCAL SCAN ACTIVE VARIABLE
	local scan_active=true 

 	#SCAN ACTIVE?
 	kill -0 "$scan_pid" >/dev/null 2>&1 && scan_active=true || scan_active=false 
		
	#ONLY ASSEMBLE IF WE NEED TO SCAN FOR ARRIVAL
	if [ "$scan_active" == false ] ; then 
		#ONCE THE LIST IS ESTABLISHED, TRIGGER SCAN OF THESE DEVICES IN THE BACKGROUND
		perform_scan "$depart_list" "$PREF_DEPART_SCAN_ATTEMPTS" & 
		scan_pid=$!
		scan_type=1
	else
		log "${GREEN}[REJECT]	${NC}Departure scan denied."
	fi
}

perform_arrival_scan () {
	log "${GREEN}[REQUEST]	${NC}Arrival scan requested."

 	#LOCAL SCAN ACTIVE VARIABLE
	local scan_active=true 

	#SET SCAN TYPE
 	local arrive_list=$(scannable_devices_with_state 0)

 	#SCAN ACTIVE?
 	kill -0 "$scan_pid" >/dev/null 2>&1 && scan_active=true || scan_active=false 
		
	#ONLY ASSEMBLE IF WE NEED TO SCAN FOR ARRIVAL
	if [ "$scan_active" == false ] ; then 
		#ONCE THE LIST IS ESTABLISHED, TRIGGER SCAN OF THESE DEVICES IN THE BACKGROUND
		perform_scan "$arrive_list" "$PREF_ARRIVAL_SCAN_ATTEMPTS" & 
		scan_pid=$!
		scan_type=0
	else
		log "${GREEN}[REJECT]	${NC}Arrival scan denied."
 
	fi 
}

# ----------------------------------------------------------------------------------------
# ADD AN ARRIVAL SCAN INTO THE QUEUE 
# ----------------------------------------------------------------------------------------

first_arrive_list=$(scannable_devices_with_state 0)
perform_scan "$first_arrive_list" "$PREF_ARRIVAL_SCAN_ATTEMPTS" & 
scan_pid=$!
scan_type=0

# ----------------------------------------------------------------------------------------
# LAUNCH BACKGROUND PROCESSES
# ----------------------------------------------------------------------------------------

log_listener &
btle_scanner & 
mqtt_listener &
btle_listener &
periodic_trigger & 
refresh_databases &

# ----------------------------------------------------------------------------------------
# MAIN LOOPS. INFINITE LOOP CONTINUES, NAMED PIPE IS READ INTO SECONDARY LOOP
# ----------------------------------------------------------------------------------------

#MAIN LOOP
while true; do 
	#READ FROM THE MAIN PIPE
	while read event; do 

		#DIVIDE EVENT MESSAGE INTO TYPE AND DATA
		cmd="${event:0:4}"
		data="${event:4}"
		timestamp=$(date +%s)

		#FLAGS TO DETERMINE FRESHNESS OF DATA
		is_new=false
		did_change=false

		#DATA FOR PUBLICATION
		manufacturer="Unknown"
		name=""

		#PROCEED BASED ON COMMAND TYPE
		if [ "$cmd" == "RAND" ]; then 
			#PARSE RECEIVED DATA
			mac=$(echo "$data" | awk -F "|" '{print $1}')
			pdu_header=$(echo "$data" | awk -F "|" '{print $2}')
			name=$(echo "$data" | awk -F "|" '{print $3}')
			data="$mac"

			#IF WE HAVE A NAME; UNSEAT FROM RANDOM AND ADD TO STATIC
			#THIS IS A BIT OF A FUDGE, A RANDOM DEVICE WITH A LOCAL 
			#NAME IS TRACKABLE, SO IT'S UNLIKELY THAT ANY CONSUMER
			#ELECTRONIC DEVICE OR CELL PHONE IS ASSOCIATED WITH THIS 
			#ADDRESS. CONSIDER THE ADDRESS AS A STATIC ADDRESS

			if [ ! -z "$name" ]; then 
				#RESET COMMAND
				cmd="PUBL"
				unset random_device_log[$data]

				#SAVE THE NAME
				known_static_device_name[$data]="$name"

				#IS THIS A NEW STATIC DEVICE?
				[ -z "${static_device_log[$data]}" ] && is_new=true
				static_device_log[$data]="$timestamp"

			else
				#IS THIS ALREADY IN THE STATIC LOG? 
				if [ ! -z  "${static_device_log[$data]}" ]; then 
					#IS THIS A NEW STATIC DEVICE?
					static_device_log[$data]="$timestamp"
					cmd="PUBL"

				else 

					#DATA IS RANDOM MAC ADDRESS; ADD TO LOG
					[ -z "${random_device_log[$data]}" ] && is_new=true

					#ONLY ADD THIS TO THE DEVICE LOG 
					random_device_log[$data]="$timestamp"
				fi 
			fi

		elif [ "$cmd" == "SCAN" ]; then 

			#ADD TO THE SCAN LOG
			known_static_device_scan_log[$data]=$(date +%s)
			continue

		elif [ "$cmd" == "DONE" ]; then 

			#SCAN MODE IS COMPLETE
			scan_pid=""

			#SET LAST ARRIVAL OR DEPARTURE SCAN
			[ "$scan_type" == "0" ] && last_arrival_scan=$(date +%s)
			[ "$scan_type" == "1" ] && last_depart_scan=$(date +%s)

			scan_type=""
			continue

		elif [ "$cmd" == "MQTT" ]; then 
			#GET INSTRUCTION 
			mqtt_topic_branch=$(basename $data)

			#NORMALIZE TO UPPERCASE
			mqtt_topic_branch=${mqtt_topic_branch^^}

			#FOR DETAILED LOGGING
			mqtt_response_required="${RED}[Rejected] ${NC}"

			if [ "$mqtt_topic_branch" == "ARRIVE" ] || [ "$mqtt_topic_branch" == "SCAN" ]; then 
				
				perform_arrival_scan
				mqtt_response_required=""

			elif [ "$mqtt_topic_branch" == "DEPART" ]; then 

				perform_departure_scan
				mqtt_response_required=""

			fi

			#IN RESPONSE TO MQTT SCAN 
			log "${GREEN}[INSTRUCT]	$mqtt_response_required${NC}MQTT Trigger $mqtt_topic_branch${NC}"

		elif [ "$cmd" == "TIME" ]; then 

			#SCANNED RECENTLY? 
			duration_since_arrival_scan=$((timestamp - last_arrival_scan))
			duration_since_depart_scan=$((timestamp - last_depart_scan))

			if [ "$duration_since_arrival_scan" -gt 30 ]; then 
				
				perform_arrival_scan

			fi 

			if [ "$duration_since_depart_scan" -gt 60 ]; then 
				
				perform_departure_scan

			fi  


		elif [ "$cmd" == "REFR" ]; then 

			#**********************************************************************
			#
			#
			#	THE FOLLOWING LOOPS CLEAR CACHES OF ALREADY SEEN DEVICES BASED 
			#	ON APPROPRIATE TIMEOUT PERIODS FOR THOSE DEVICES. 
			#	
			#
			#**********************************************************************
			#DID ANY DEVICE EXPIRE? 
			should_scan=false

			#PURGE OLD KEYS FROM THE RANDOM DEVICE LOG
			random_bias=0
			for key in "${!random_device_log[@]}"; do
				#GET BIAS
				random_bias=${device_expiration_biases[$key]}
				[ -z "$random_bias" ] && random_bias=0 

				#DETERMINE THE LAST TIME THIS MAC WAS LOGGED
				last_seen=${random_device_log[$key]}
				difference=$((timestamp - last_seen))

				#CONTINUE IF DEVICE HAS NOT BEEN SEEN OR DATE IS CORRUPT
				[ -z "$last_seen" ] && continue 

				#TIMEOUT AFTER 120 SECONDS
				if [ "$difference" -gt "$((300 + random_bias))" ]; then 
					unset random_device_log[$key]
					log "${BLUE}[CLEARED]	${NC}$key expired after $difference seconds RAND_NUM: ${#random_device_log[@]}  ${NC}"

					#UPDATE TIMESTAMP
					random_device_last_update=$(date +%s)
			
					#AT LEAST ONE DEVICE EXPIRED
					should_scan=true 

					#ADD TO THE EXPIRED LOG
					expired_device_log[$key]=$timestamp
				fi 
			done

			if [ "$should_scan" == true ]; then 
				
				perform_departure_scan

			fi  

			#PURGE OLD KEYS FROM THE BEACON DEVICE LOG
			beacon_bias=0
			for key in "${!static_device_log[@]}"; do
				#GET BIAS
				beacon_bias=${device_expiration_biases[$key]}
				[ -z "$beacon_bias" ] && beacon_bias=0 

				#DETERMINE THE LAST TIME THIS MAC WAS LOGGED
				last_seen=${static_device_log[$key]}
				difference=$((timestamp - last_seen))

				#CONTINUE IF DEVICE HAS NOT BEEN SEEN OR DATE IS CORRUPT
				[ -z "$last_seen" ] && continue 

				#TIMEOUT AFTER 120 SECONDS
				if [ "$difference" -gt "$(( 180 + beacon_bias ))" ]; then 
					unset static_device_log[$key]
					log "${BLUE}[CLEARED]	${NC}$key expired after $difference seconds PUBL_NUM: ${#static_device_log[@]}  ${NC}"

					#ADD TO THE EXPIRED LOG
					expired_device_log[$key]=$timestamp
				fi 
			done

		elif [ "$cmd" == "PUBL" ]; then 
			#PARSE RECEIVED DATA
			mac=$(echo "$data" | awk -F "|" '{print $1}')
			pdu_header=$(echo "$data" | awk -F "|" '{print $2}')
			name=$(echo "$data" | awk -F "|" '{print $3}')
			data="$mac"

			#DATA IS PUBLIC MAC ADDRESS; ADD TO LOG
			[ -z "${static_device_log[$data]}" ] && is_new=true

			static_device_log[$data]="$timestamp"
			manufacturer="$(determine_manufacturer $data)"

		elif [ "$cmd" == "NAME" ]; then 
			#DATA IS DELIMITED BY VERTICAL PIPE
			mac=$(echo "$data" | awk -F "|" '{print $1}')
			name=$(echo "$data" | awk -F "|" '{print $2}')
			data="$mac"

			#PREVIOUS STATE; SET DEFAULT TO UNKNOWN
			previous_state="${known_static_device_log[$mac]}"
			[ -z "$previous_state" ] && previous_state=-1

			#GET MANUFACTURER INFORMATION
			manufacturer="$(determine_manufacturer $data)"

			#IF NAME IS DISCOVERED, PRESUME HOME
			if [ ! -z "$name" ]; then 
				known_static_device_log[$mac]=1
				[ "$previous_state" != "1" ] && did_change=true
			else
				known_static_device_log[$mac]=0
				[ "$previous_state" != "0" ] && did_change=true
			fi 

		elif [ "$cmd" == "BEAC" ]; then 
			#DATA IS DELIMITED BY VERTICAL PIPE
			uuid=$(echo "$data" | awk -F "|" '{print $1}')
			major=$(echo "$data" | awk -F "|" '{print $2}')
			minor=$(echo "$data" | awk -F "|" '{print $3}')
			rssi=$(echo "$data" | awk -F "|" '{print $4}')
			power=$(echo "$data" | awk -F "|" '{print $5}')

			#GET MAC AND PDU HEADER
			mac=$(echo "$data" | awk -F "|" '{print $6}')
			pdu_header=$(echo "$data" | awk -F "|" '{print $7}')
			manufacturer="$(determine_manufacturer $mac)"

			#KEY DEFINED AS UUID-MAJOR-MINOR
			data="$mac"
			[ -z "${static_device_log[$data]}" ] && is_new=true
			static_device_log[$data]="$timestamp"	

			#GET MANUFACTURER INFORMATION
			manufacturer="$(determine_manufacturer $uuid)"			
		fi

		#**********************************************************************
		#
		#
		#	THE FOLLOWING INCREASES DEVICE BAISES IF A DEVICE RE-
		#	APPEARS AFTER A SHORT AMOUNT OF TIME (2 MINUTES)
		#	
		#
		#**********************************************************************

		if [ "$is_new" == true ]; then 

			#GET CURRENT BIAS
			bias=${device_expiration_biases[$data]}
			[ -z "$bias" ] && bias=0

			#WHEN DID THIS LAST EXPIRE?
			last_expired=${expired_device_log[$data]}
			difference=$((timestamp - last_expired))

			#DO WE NEED TO ADD A LEANRED BIAS FOR EXPIRATION?
			if [ "$difference" -lt "120" ]; then 
				device_expiration_biases[$data]=$(( bias + 15 ))
			fi  
		fi 

		#**********************************************************************
		#
		#
		#	THE FOLLOWING CONDITIONS DEFINE BEHAVIOR WHEN A DEVICE ARRIVES
		#	OR DEPARTS
		#	
		#
		#**********************************************************************

		#ECHO VALUES FOR DEBUGGING
		if [ "$cmd" == "NAME" ] ; then 
			
			#PRINTING FORMATING
			debug_name="$name"
			expected_name="${known_static_device_name[$data]}"
			current_state="${known_static_device_log[$mac]}"

			#IF NAME IS NOT PREVIOUSLY SEEN, THEN WE SET THE STATIC DEVICE DATABASE NAME
			[ -z "$expected_name" ] && [ ! -z "$name" ] && known_static_device_name[$data]="$name" 
			[ ! -z "$expected_name" ] && [ -z "$name" ] && name="$expected_name"

			#OVERWRITE WITH EXPECTED NAME
			[ ! -z "$expected_name" ] && [ ! -z "$name" ] && name="$expected_name"

			#FOR LOGGING; MAKE SURE THAT AN UNKNOWN NAME IS ADDED
			if [ -z "$debug_name" ]; then 
				#SHOW ERROR
				debug_name="${RED}[Error] Unknown Name ${NC}"
				
				#CHECK FOR KNOWN NAME
				[ ! -z "$expected_name" ] && debug_name="${RED}[Error] $expected_name${NC}"
			fi 

			#DEVICE FOUND; IS IT CHANGED? IF SO, REPORT THE CHANGE
			[ "$did_change" == true ] && publish_message "owner/$mqtt_publisher_identity/$data" "$((current_state * 100))" "$name" "$manufacturer"
			
			#PRINT RAW COMMAND; DEBUGGING
			log "${CYAN}[CMD-$cmd]	${NC}$data ${GREEN}$debug_name ${NC} $manufacturer $did_change${NC}"
		
		elif [ "$cmd" == "BEAC" ] ; then 

			#DOES AN EXPECTED NAME EXIST? 
			expected_name="${known_static_device_name[$data]}"

			#PRINTING FORMATING
			[ -z "$expected_name" ] && expected_name="${RED}[Error]${NC}"
		
			#PROVIDE USEFUL LOGGING
			log "${GREEN}[CMD-$cmd]	${NC}$data ${GREEN}$uuid $major $minor ${NC}$expected_name${NC} $manufacturer${NC}"
		
		elif [ "$cmd" == "PUBL" ] && [ "$is_new" == true ] ; then 

			#IF IS NEW AND IS PUBLIC, SHOULD CHECK FOR NAME
			expected_name="${known_static_device_name[$data]}"

			#FIND PERMANENT DEVICE NAME OF PUBLIC DEVICE
			if [ -z "$expected_name" ]; then 

			 	kill -0 "$scan_pid" >/dev/null 2>&1 && scan_active=true || scan_active=false 

			 	#ONLY SCAN IF WE ARE NOT OTHERWISE SCANNING; NAME FOR THIS DEVICE IS NOT IMPORTANT
			 	if [ "$scan_active" == false ]; then 

					#FIND NAME OF THIS DEVICE
					expected_name=$(hcitool name "$data" | grep -ivE 'input/output error|invalid device|invalid|error')

					#IS THE EXPECTED NAME BLANK? 
					if [ -z "$expected_name" ]; then 
						expected_name="${RED}[Error]${NC}"
					else 
						known_static_device_name[$data]="$expected_name"
					fi 
				fi 
			fi 

			#PROVIDE USEFUL LOGGING
			log "${PURPLE}[CMD-$cmd]${NC}	$data $pdu_header ${GREEN}$expected_name${NC} ${BLUE}$manufacturer${NC} PUBL_NUM: ${#static_device_log[@]}"

		elif [ "$cmd" == "RAND" ] && [ "$is_new" == true ] ; then 
			#PROVIDE USEFUL LOGGING
			log "${RED}[CMD-$cmd]${NC}	$data $pdu_header $name RAND_NUM: ${#random_device_log[@]}"
			
		 	perform_arrival_scan 
		fi 

	done < main_pipe
done