#!/usr/bin/awk -f

# Replace values in a PKGBUILD file
#
# Usage: update-PKGBUILD.awk [/path/to/PKGBUILD] <option>=<value>...
#
# The first occurrence of each <option> in the input is replaced with <value>.

# Map <option>=<value> arguments to val[<option>] = <value> and remove them from
# ARGV so awk doesn't treat them filenames
BEGIN {
	for (i = 1; i < ARGC; i++) {
		if (split(ARGV[i], a, /=/) && a[1]) {
			sub(/^[^=]+=/, "", ARGV[i])
			val[a[1]] = ARGV[i]
			ARGV[i] = ""
		}
	}
	FS = "="
}

# Replace one-line PKGBUILD entries
! in_val && /^[^ \t=]+=([^(]|(\(.*\))?[ \t]*$)/ && val[$1] {
	print $1 "=" val[$1]
	val[$1] = ""
	next
}

# Collect PKGBUILD arrays that span multiple lines
! in_val && /^[^ \t=]+=\((.*[^ \t)])?[ \t]*$/ {
	in_val = $1
	in_val_lines = $0
	next
}

# When the last line of a multi-line entry is reached, replace it or print the
# entire entry as-is
in_val && /\)[ \t]*$/ {
	if (val[in_val]) {
		print in_val "=" val[in_val]
		val[in_val] = ""
	} else {
		print in_val_lines
		print
	}
	in_val = ""
	next
}

in_val {
	in_val_lines = in_val_lines "\n" $0
	next
}

{
	# Print other lines as-is
	print
}

