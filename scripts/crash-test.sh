#!/usr/bin/env bash

bin=`dirname "$0"`
bin=`cd "$bin"; pwd`

REPORT_FILE=""

optspec=":h-:"
while getopts "$optspec" optchar; do
    case "${optchar}" in
        -) 
            case "${OPTARG}" in
               	report=*)
                    REPORT_FILE=${OPTARG#*=}
                    opt=${OPTARG%=$REPORT_FILE}
                    #echo "Parsing option: '--${opt}', value: '${FROM_VALUE}'" >&2
                    ;;
                *)
                    echo "Unknown option --${OPTARG}" >&2
					exit 2;
                    ;;
            esac;;
        h)
			echo "Usage:   $0 /dfs/path/to/file \"set0|set1|set2...\"";
			echo "         where setX is a comma separated list of block numbers.";
			echo "Example: $0 /user/hduser/bob.dat 0,1|5,9|8,3";
			echo "         $0 --report=/path/to/output/file /user/hduser/bob.dat 0,1|5,9|8,3";
			exit 1;
            ;;
        *)
            echo "Unknown option -${OPTARG}" >&2
			exit 2;
            ;;
    esac
done
shift $(($OPTIND - 1))

if [ $# -lt 2 ]; then
	echo "Usage:   $0 /dfs/path/to/file \"set0|set1|set2...\"";
	echo "         where setX is a comma separated list of block numbers.";
	echo "Example: $0 /user/hduser/bob.dat 0,1|5,9|8,3";
	exit 1;
fi

DFS_PATH="$1";
shift;
BLOCK_SETS="$1";
shift;

# Verify that BLOCK_SETS has the correct format
BLOCK_SETS=$(echo "$BLOCK_SETS" | grep -E '^(\s*[0-9]+\s*)(,\s*[0-9]+\s*)*(\|(\s*[0-9]+\s*)(,\s*[0-9]+\s*)*)*$');
if [ $? -ne 0 ]; then
	echo "error: second argument must be a list of block-sets.">&2;
	exit 1;
fi
BLOCK_SETS=$(echo "$BLOCK_SETS" | perl -p -e 's/\s//g');
BLOCK_SETS=$(echo "$BLOCK_SETS" | perl -p -e 's/\|/\n/g;s/,/ /g');
#echo $BLOCK_SETS;

NUM_OF_BLOCK_SETS=$(echo "$BLOCK_SETS" | wc -l);

echo "DFS PATH: $DFS_PATH";

# Check if file exists
${HADOOP_HOME}/bin/hadoop dfs -test -e $DFS_PATH
if [ $? -ne 0 ]; then
	echo "error: file not found">&2;
	exit 1;
fi

# Checking if file is healthy prior to starting test
fsck_output=$(hadoop fsck $DFS_PATH 2>/dev/null);
isCorrupt=$(echo "$fsck_output" | grep -c "CORRUPT");
if [[ $isCorrupt -gt 0 ]]; then
	echo "error: file is already corrupted. Aborting test">&2;
	exit 1;
fi


# Iterate over block-sets.
for i in $(seq 1 $NUM_OF_BLOCK_SETS);
do
	# For each block set
	# - delete the block
	# - wait for corruption to be detected
	# - wait for file to be fixed

	#===========================================================================

	timestampstart=$(date +%Y%m%d%H%M%S);

	BLOCK_SET=$(echo "$BLOCK_SETS" | awk "NR==$i");

	echo "Delete blocks: $BLOCK_SET"
	result=$(${bin}/del-block.sh $DFS_PATH $BLOCK_SET);
	if [ $? -ne 0 ]; then
		echo "error: deleting blocks. Abort">&2;
		exit 1;	
	fi
	echo "$result";
	if [ -z "$result" ]; then
		echo "error: processing del-blocks output (1). Abort">&2;
		exit 1;
	fi

	result=$(echo "$result" | sed 's/.*(\(.*\)).*/\1/g');
	if [ -z "$result" ]; then
		echo "error: processing del-blocks output (2). Abort">&2;
		exit 1;
	fi


	res_total=$(echo $result | cut -d',' -f1 | cut -d'=' -f2);
	res_deleted=$(echo $result | cut -d',' -f2 | cut -d'=' -f2);
	res_failed=$(echo $result | cut -d',' -f3 | cut -d'=' -f2);
	res_missing=$(echo $result | cut -d',' -f4 | cut -d'=' -f2);

	if [ $res_failed -eq $res_total ]; then
		echo "warn: deleting all blocks failed.">&2;
		continue;
	fi

	#===========================================================================

	echo -n "Wait for raid to detect corruption.."
	CHECK_INTERVAL=10;
	while true; do

		fsck_output=$(hadoop fsck $DFS_PATH 2>&1);
		isCorrupt=$(echo "$fsck_output" | grep -c "CORRUPT");
		isHealthy=$(echo "$fsck_output" | grep -c "HEALTHY");
		
		if [[ $isCorrupt -eq 0 && $isHealthy -gt 0 ]]; then
			echo -n "."
			sleep $CHECK_INTERVAL;
			continue;
		elif [[ $isCorrupt -gt 0 && $isHealthy -eq 0 ]]; then
			echo " detected."
			break;
		else
			echo "unhandled case (1): debug: $fsck_output">&2;
			exit 1;
		fi
	done

	#===========================================================================

	echo -n "Wait for raid to repair path.."
	CHECK_INTERVAL=10;
	while true; do
	
		fsck_output=$(hadoop fsck $DFS_PATH 2>&1);
		running_jobs=$(${HADOOP_HOME}/bin/hadoop job -list | grep "jobs currently running" | awk -F" " '{ print $1}');


		isCorrupt=$(echo "$fsck_output" | grep -c "CORRUPT");
		isHealthy=$(echo "$fsck_output" | grep -c "HEALTHY");
		
		if [[ $isCorrupt -gt 0 && $isHealthy -eq 0 ]]; then
			echo -n ".";
			sleep $CHECK_INTERVAL;
			continue;
		elif [[ $isCorrupt -eq 0 && $isHealthy -gt 0 ]]; then
			if [[ $running_jobs -gt 0 ]]; then
				echo -n ".";
				sleep $CHECK_INTERVAL;
				continue;
			else
				echo " repaired.";
				break;
			fi
		else
			echo "unhandled case (2): debug: $fsck_output, $running_jobs">&2;
			exit 1;
		fi
	done

	timestampend=$(date +%Y%m%d%H%M%S);
	
	bytesread=$(${bin}/get-jobs-counter.sh --from=$timestampstart --to=$timestampend "HDFS_BYTES_READ" | cut -f2 | awk '{s+=$1} END {print s}');

	echo "Total HDFS bytes read: $bytesread"
	if [ -n "$REPORT_FILE" ]; then
		echo -e "$timestampstart\t$timestampend\t$res_deleted\t$bytesread" >> $REPORT_FILE;
	fi
done

