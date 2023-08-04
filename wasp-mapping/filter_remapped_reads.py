
import argparse
import sys

import pysam



def parse_options():
    parser = argparse.ArgumentParser(description="This program checks "
                                     "whether reads that overlap SNPs map "
                                     "back to the same location as the "
                                     "original reads after their alleles "
                                     "are flipped by the "
                                     "find_intersecting_snps.py script. "
                                     "Reads where one or more allelic versions "
                                     "map to a different location (or fail "
                                     "to map) are discarded. Reads that are "
                                     "kept are written to the specified "
                                     "keep_bam output file. Reads in the "
                                     "input remap_bam file are expected to "
                                     "have read names encoding the original "
                                     "map location and number of allelic "
                                     "variants. Specifically, the read names "
                                     "should be delimited with the '.' "
                                     "character and "
                                     "contain the following fields: "
                                     "<orig_name>.<coordinate>."
                                     "<read_number>.<total_read_number>. "
                                     "These read names are "
                                     "generated by the "
                                     "find_intersecting_snps.py script.")
    
    parser.add_argument("to_remap_bam", help="input BAM file containing "
                        "original set of reads that needed to "
                        "be remapped after having their alleles flipped."
                        " This file is output by the find_intersecting_snps.py "
                        "script.")
    parser.add_argument("remap_bam", help="input BAM file containing "
                        "remapped reads (with flipped alleles)")
    parser.add_argument("keep_bam", help="output BAM file to write "
                        "filtered set of reads to")

    return parser.parse_args()


class ReadStats:
    """Track information about what the program is doing with reads"""
    def __init__(self):
        # reads from original file that were kept:
        self.keep = 0

        # reads from original file that were labeled as 'bad' e.g.
        # due to remapping issues
        self.bad = 0

        # reads from original file that were discarded
        self.discard = 0

        # reads that were not present in original file
        self.not_present = 0
        
        # paired read where only one read was observed
        self.pair_missing = 0
        
        # reads that were discarded because they (or their pair) remapped with
        # a different cigar string
        self.cigar_mismatch = 0
        self.cigar_missing = 0
        

    def write(self):
        sys.stderr.write("keep reads: %d\n" % self.keep)
        sys.stderr.write("bad reads: %d\n" % self.bad)
        sys.stderr.write("not present reads: %d\n" % self.not_present)
        sys.stderr.write("discard reads: {}\n".format(self.discard))
        sys.stderr.write("  CIGAR mismatch {}\n".format(self.cigar_mismatch))
        sys.stderr.write("  CIGAR missing or multiple: {}\n".format(self.cigar_missing))
        sys.stderr.write("  mate pair missing: {}\n".format(self.pair_missing))


def filter_reads(remap_bam):
    # dictionary to keep track of how many times a given read is observed
    read_counts = {}

    # names of reads that should be kept
    keep_reads = set([])
    bad_reads = set([])

    # a dictionary of lists for each read
    # each list contains two sets of CIGAR strings, one for each pair
    cigar_strings = {}
    
    for read in remap_bam:        
        # parse name of read, which should contain:
        # 1 - the original name of the read
        # 2 - the coordinate that it should map to
        # 3 - the number of the read
        # 4 - the total number of reads being remapped
        words = read.qname.split(".")
        if len(words) < 4:
            raise ValueError("expected read names to be formatted "
                             "like <orig_name>.<coordinate>."
                             "<read_number>.<total_read_number> but got "
                             "%s" % read.qname)

        # token separator '.' can potentially occur in
        # original read name, so if more than 4 tokens,
        # assume first tokens make up original read name
        orig_name = ".".join(words[0:len(words)-3])
        coord_str, num_str, total_str = words[len(words)-3:]
        num = int(num_str)
        total = int(total_str)


        # only keep primary alignments and discard 'secondary'
        # and 'supplementary' alignments
        if read.is_secondary or read.is_supplementary:
            bad_reads.add(orig_name)
            continue
        
        # add the cigars for this read

        # pysam used to give back read1 and read2 flagged consistently,
        # however something now seems broken with the flags. Not sure if
        # this reflects a change in pysam HTSeqLib or elsewhere. Regardless
        # to make WASP robust to this issue, no longer tracking whether a
        # CIGAR corresponds to read1 or read2. This could
        # potentially result in a mapping bias for a very small number of reads
        # (i.e. if read1 and read2 remap to same location with new CIGARs,
        # but the new read1 CIGAR happens to match the old read2 CIGAR and
        # vice-versa, but number is likely to be miniscule.

        if(orig_name in cigar_strings):
            cigar_strings[orig_name].add(read.cigarstring)
        else:
            cigar_strings[orig_name] = set([read.cigarstring])

        correct_map = False
        
        if '-' in coord_str:
            # paired end read, coordinate gives expected positions for each end
            c1, c2 = coord_str.split("-")

            if not read.is_paired:
                bad_reads.add(orig_name)
                continue
            if not read.is_proper_pair:
                bad_reads.add(orig_name)
                continue
            
            pos1 = int(c1)
            pos2 = int(c2)
            if pos1 < pos2:
                left_pos = pos1
                right_pos = pos2
            else:
                left_pos = pos2
                right_pos = pos1
                
            # only use left end of reads, but check that right end is in
            # correct location
            if read.pos < read.next_reference_start or (read.pos == read.next_reference_start and read.is_read1 and not read.is_read2):
                if pos1 == read.pos+1 and pos2 == read.next_reference_start+1:
                    # both reads mapped to correct location
                    correct_map = True
            else:
                # this is right end of read
                continue
        else:
            # single end read
            pos = int(coord_str)

            if pos == read.pos+1:
                # read maps to correct location
                correct_map = True

        if correct_map:
            if orig_name in read_counts:
                read_counts[orig_name] += 1
            else:
                read_counts[orig_name] = 1

            if read_counts[orig_name] == total:
                # all alternative versions of this read
                # mapped to correct location
                if orig_name in keep_reads:
                    raise ValueError("saw read %s more times than "
                                     "expected in input file" % orig_name)
                keep_reads.add(orig_name)

                # remove read from counts to save mem
                del read_counts[orig_name]
        else:
            # read maps to different location
            bad_reads.add(orig_name)

    #sys.stderr.write("keep_reads: %d, bad_reads: %d\n" % (len(keep_reads), len(bad_reads)))
    #sys.stderr.write("%d reads did not have all versions map\n" % (len(read_counts)))
            
    return keep_reads, bad_reads, cigar_strings


def write_reads(to_remap_bam, keep_bam, keep_reads, bad_reads, cigar_strings):
    """writes reads but also checks cigar strings"""

    stats = ReadStats()
    
    read_pair_cache = {}

    for read in to_remap_bam:
        if read.qname in bad_reads:
            stats.bad += 1
        elif read.qname in keep_reads:
            if read.is_paired:
                # cache reads until you see their pair
                # then, write both of them to file together
                if read.qname in read_pair_cache:
                    #
                    # check that the CIGAR strings match up
                    # for both reads.
                    # NOTE: 2/8/2021 Code used to assume that read1 and read2 stayed defined as
                    # read1 and read2 following re-alignment. Observed that read1 and read2 sometimes
                    # switch. Changed code to allow for this possibility.
                    r1 = read_pair_cache[read.qname]
                    r2 = read

                    # remove read from cache
                    del read_pair_cache[read.qname]

                    cigs = cigar_strings[read.qname]


                    if len(cigs) == 1:
                        # both reads had same CIGAR in original mapping
                        if (r1.cigarstring == r2.cigarstring) and \
                           (r1.cigarstring in cigs):
                            # Both R1 and R2 cigar strings are the same
                            # and match CIGAR from original mapping
                            stats.keep += 2
                            keep_bam.write(r1)
                            keep_bam.write(r2)
                        else:
                            stats.cigar_mismatch += 1
                            stats.discard += 1
                    elif len(cigs) == 2:
                        # both reads had different CIGAR in original mapping
                        if (r1.cigarstring != r2.cigarstring) and \
                           (r1.cigarstring in cigs) and \
                           (r2.cigarstring in cigs):
                            # verified CIGARs are different and 
                            # were both present in original mapping
                            stats.keep += 2
                            keep_bam.write(r1)
                            keep_bam.write(r2)
                        else:
                            stats.cigar_mismatch += 1
                            stats.discard += 1
                    else:
                        # There were no CIGARs or >2 CIGARs in original mapping
                        # This is unexpected and we don't handle this case.
                        stats.cigar_missing += 1
                        stats.discard += 1
                        
                else:
                    # cache this read
                    read_pair_cache[read.qname] = read
            else:
                # single-end read
                if (len(cigar_strings[read.qname]) != 1):
                    # currently don't handle missing/multiple CIGARs
                    stats.cigar_missing += 1
                    stats.discard += 1
                else:
                    if (read.cigarstring in cigar_strings[read.qname]):
                        keep_bam.write(read)
                        stats.keep += 1
                    else:
                        stats.cigar_mismatch += 1
                        stats.discard += 1
        else:
            # read was not labeled as 'keep' or 'bad' in original file
            stats.not_present += 1

    # any reads remaining in the cache have been discarded
    stats.pair_missing += len(read_pair_cache)
    stats.discard += len(read_pair_cache)
    

    stats.write()
    

    
def main(to_remap_bam_path, remap_bam_path, keep_bam_path):
    to_remap_bam = pysam.Samfile(to_remap_bam_path)
    remap_bam = pysam.Samfile(remap_bam_path)
    keep_bam = pysam.Samfile(keep_bam_path, "wb", template=to_remap_bam)

    keep_reads, bad_reads, cigar_strings = filter_reads(remap_bam)
    
    write_reads(to_remap_bam, keep_bam, keep_reads, bad_reads, cigar_strings)
        


if __name__ == "__main__":
    options = parse_options()
    main(options.to_remap_bam, options.remap_bam, options.keep_bam)
