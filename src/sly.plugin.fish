# Fish integration for sly - AI-powered shell command generator
# Provides the "# <request>" + Enter UX, replaces buffer with the command.
#
# Environment variables:
#   SLY_TIMEOUT  - Generation timeout in seconds (default: 30)
#   SLY_SPINNER  - Enable/disable spinner animation (default: 1)
#   SLY_COLOR    - Enable/disable color output (default: 1)

# Portable timeout function (uses fish's timeout if available, or gtimeout)
function __sly_run_with_timeout
    set -l timeout_secs $argv[1]
    set -e argv[1]
    
    if command -v timeout >/dev/null 2>&1
        timeout $timeout_secs $argv
    else if command -v gtimeout >/dev/null 2>&1
        gtimeout $timeout_secs $argv
    else
        # No timeout available, run directly (warn once)
        if not set -q __SLY_TIMEOUT_WARNED
            if test "$SLY_COLOR" != "0"
                set_color yellow
                echo "⚠ sly: timeout command not found, running without timeout" >&2
                set_color normal
            else
                echo "sly: timeout command not found, running without timeout" >&2
            end
            set -g __SLY_TIMEOUT_WARNED 1
        end
        $argv
    end
end

function __sly_expand
    # Get current command line
    set -l current_buffer (commandline)
    
    # Only process if line starts with "# "
    if not string match -q '# *' -- $current_buffer
        return
    end
    
    # Ensure sly binary is available
    if not command -v sly >/dev/null 2>&1
        if test "$SLY_COLOR" != "0"
            set_color red
            echo "❌ sly: command not found (is it on PATH?)"
            set_color normal
        else
            echo "sly: command not found (is it on PATH?)"
        end
        commandline -r ""
        return
    end
    
    # Extract query (remove "# " prefix)
    set -l query (string sub -s 3 -- $current_buffer)
    
    # Empty query - just clear buffer and return
    if test -z (string trim -- "$query")
        commandline -r ""
        return
    end
    
    # Capture context from history
    set -l context ""
    set -l history_entries (history --max 10)
    if test (count $history_entries) -gt 0
        set context (string join "\n" -- $history_entries)
    end
    
    # Add current buffer as context
    if test -n "$current_buffer"
        if test -n "$context"
            set context "$context\nCurrent buffer: $current_buffer"
        else
            set context "Current buffer: $current_buffer"
        end
    end
    
    # Set timeout
    set -l timeout_val 30
    if set -q SLY_TIMEOUT
        set timeout_val $SLY_TIMEOUT
    end
    
    # Call sly plan with optional spinner
    set -l tmp (mktemp -t sly.XXXXXX)
    
    # Track if we were interrupted
    set -l interrupted 0
    
    # Set up interrupt handler
    function __sly_on_interrupt --on-signal INT
        set interrupted 1
    end
    
    if test -n "$context"
        __sly_run_with_timeout $timeout_val sly plan --query "$query" --context "$context" >$tmp 2>/dev/null &
    else
        __sly_run_with_timeout $timeout_val sly plan --query "$query" >$tmp 2>/dev/null &
    end
    set -l pid $last_pid
    
    # Spinner animation (can be disabled with SLY_SPINNER=0)
    set -l spinner_enabled 1
    if set -q SLY_SPINNER
        set spinner_enabled $SLY_SPINNER
    end
    
    if test "$spinner_enabled" != "0"
        set -l spinner_chars "⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"
        set -l i 1
        while kill -0 $pid 2>/dev/null
            if test $interrupted -eq 1
                kill -TERM $pid 2>/dev/null
                break
            end
            printf '\rGenerating... %s' $spinner_chars[$i]
            set i (math "($i % 10) + 1")
            sleep 0.1
        end
        printf '\r%s\r' "                "
    else
        # No spinner, just wait
        while kill -0 $pid 2>/dev/null
            if test $interrupted -eq 1
                kill -TERM $pid 2>/dev/null
                break
            end
            sleep 0.1
        end
    end
    
    # Clean up interrupt handler
    functions -e __sly_on_interrupt
    
    # Handle interrupt
    if test $interrupted -eq 1
        rm -f $tmp
        commandline -r ""
        return
    end
    
    # Wait for background job and get exit status
    wait $pid 2>/dev/null
    set -l wait_rc $status
    set -l plan_json (cat $tmp)
    rm -f $tmp
    
    # Check for timeout (exit code 124)
    if test $wait_rc -eq 124
        if test "$SLY_COLOR" != "0"
            set_color red
            echo "❌ Generation timed out after "$timeout_val"s"
            set_color normal
        else
            echo "Generation timed out after "$timeout_val"s"
        end
        commandline -r ""
        return
    end
    
    # Parse JSON response
    if test -n "$plan_json"; and not string match -q 'Error:*' -- $plan_json; and not string match -q 'API Error:*' -- $plan_json
        set -l cmd
        
        if command -v jq >/dev/null 2>&1
            # Validate that .command exists
            if not printf '%s\n' "$plan_json" | jq -e '.command' >/dev/null 2>&1
                if test "$SLY_COLOR" != "0"
                    set_color red
                    echo "❌ Invalid response: missing command field"
                    set_color normal
                else
                    echo "Invalid response: missing command field"
                end
                commandline -r ""
                return
            end
            # Parse with jq
            set cmd (printf '%s\n' "$plan_json" | jq -r '.command as $cmd | [$cmd, ((.args // [])[] | @sh)] | join(" ")' 2>/dev/null)
        else
            # Fallback: simple extraction using string manipulation
            set -l base_cmd (echo $plan_json | string match -r '"command"\s*:\s*"([^"]*)"' | head -2 | tail -1)
            
            if test -z "$base_cmd"
                if test "$SLY_COLOR" != "0"
                    set_color red
                    echo "❌ Invalid response: could not parse command"
                    set_color normal
                else
                    echo "Invalid response: could not parse command"
                end
                commandline -r ""
                return
            end
            
            # Extract args (simplified - may not handle all cases)
            set -l args_raw (echo $plan_json | string match -r '"args"\s*:\s*\[([^\]]*)\]' | head -2 | tail -1)
            set -l args_str (echo $args_raw | string replace -ra '"' '' | string replace -a ',' ' ')
            
            if test -n "$args_str"
                set cmd "$base_cmd $args_str"
            else
                set cmd $base_cmd
            end
        end
        
        if test -n "$cmd"
            # Replace the command line with the generated command
            commandline -r $cmd
            commandline -f end-of-line
        else
            if test "$SLY_COLOR" != "0"
                set_color red
                echo "❌ Failed to parse command from plan"
                set_color normal
            else
                echo "Failed to parse command from plan"
            end
            commandline -r ""
        end
    else
        if test "$SLY_COLOR" != "0"
            set_color red
            echo "❌ Failed to generate command plan"
            if test -n "$plan_json"
                echo $plan_json
            end
            set_color normal
        else
            echo "Failed to generate command plan"
            if test -n "$plan_json"
                echo $plan_json
            end
        end
        commandline -r ""
    end
end

# Key binding for Enter key - intercept "# query" pattern
function __sly_maybe_enter
    set -l current_buffer (commandline)
    
    if string match -q '# *' -- $current_buffer
        # Expand the query and leave command in buffer (don't execute)
        __sly_expand
    else
        # Execute the command normally
        commandline -f execute
    end
end

# Bind Enter to our wrapper function
bind \r __sly_maybe_enter
bind \n __sly_maybe_enter
