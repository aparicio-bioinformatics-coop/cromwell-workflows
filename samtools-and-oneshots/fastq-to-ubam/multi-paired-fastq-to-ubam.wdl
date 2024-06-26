version 1.0

## Copyright Broad Institute, 2018
## 
## This WDL converts paired FASTQs to a uBAM
##
## Requirements/expectations:
## - Pair-end sequencing data in FASTQ format (one file per orientation, i.e. read 1 + read 2)
##
## Outputs :
## - an unmapped BAM
##
## Cromwell version support 
## - Successfully tested on v47
## - Does not work on versions < v23 due to output syntax
##
## Runtime parameters are optimized for Broad's Google Cloud Platform implementation. 
## For program versions, see docker containers. 
##
## LICENSING : 
## This script is released under the WDL source code license (BSD-3) (see LICENSE in 
## https://github.com/broadinstitute/wdl). Note however that the programs it calls may 
## be subject to different licenses. Users are responsible for checking that they are
## authorized to run all programs before running this script. Please see the docker 
## page at https://hub.docker.com/r/broadinstitute/genomes-in-the-cloud/ for detailed
## licensing information pertaining to the included programs.
##
## Updated by Aparicio Lab (BC Cancer Research Centre) July 2023 to optimize runtime
## parameters for Cromwell on Azure implementation (instead of Google Cloud).

struct SampleMetadata {
	String readgroup_name
	String library_name
	String platform_unit
  String platform_name
  String run_date
  String sequencing_center
}

struct Fastqs {
	File fastq_1
	File fastq_2
}

# WORKFLOW DEFINITION
workflow ConvertPairedFastqsToUbam {
  input {
    SampleMetadata metadata
    Array[Pair[String, Fastqs]] fastq_pairs

    Int compression_level = 5

    String gotc_docker = "us.gcr.io/broad-gotc-prod/genomes-in-the-cloud:2.5.7-2021-06-09_16-47-48Z"
    String gotc_path = "/usr/gitc/"
    
    # Sometimes the output is larger than the input, or a task can spill to disk.
    # In these cases we need to account for the input (1) and the output (1.5) or the input(1), the output(1), and spillage (.5).
    Float disk_multiplier = 10 # 2.5 -> 4 (increased b/c VM was running out)
  }

  meta {allowNestedInputs: true}

  # Convert pair of FASTQs to uBAM
  scatter(pair in fastq_pairs) {
    String output_name = pair.left
    Fastqs fastqs = pair.right

    call ConvertPairedFastqs {
      input: 
        library_name = metadata.library_name, 
        fastq_1 = fastqs.fastq_1, 
        fastq_2 = fastqs.fastq_2, 
        readgroup_name = metadata.readgroup_name, 
        library_name = metadata.library_name, 
        platform_unit = metadata.platform_unit, 
        platform_name = metadata.platform_name, 
        run_date = metadata.run_date, 
        sequencing_center = metadata.sequencing_center, 

        disk_multiplier = disk_multiplier, 
        output_bam_basename = output_name + ".unmapped.bam",
        compression_level = compression_level,
        gotc_docker = gotc_docker,
        disk_multiplier = disk_multiplier
    }
  }

  output {
    Array[File] ubam = ConvertPairedFastqs.output_unmapped_bam
  }
}

# TASK DEFINITIONS

# Convert a pair of FASTQs to uBAM
task ConvertPairedFastqs {
  input {
    # Command parameters
    File fastq_1
    File fastq_2
    String output_bam_basename
    String readgroup_name
    String library_name
    String platform_unit
    String platform_name
    String run_date
    String sequencing_center
    String gotc_docker
    Int compression_level

    # Runtime parameters
    Int addtional_disk_space_gb = 10
    Int machine_mem_gb = 7
    Int preemptible_attempts = 3
    Float disk_multiplier
  }
    Int command_mem_gb = machine_mem_gb - 1
    Float fastq_size = size(fastq_1, "GB")
    Int disk_space_gb = ceil(fastq_size + (fastq_size * disk_multiplier ) + addtional_disk_space_gb)
  
  command <<<
    java -Dsamjdk.compression_level=~{compression_level} -Xms4000m -jar /usr/gitc/picard.jar \
    FastqToSam \
    F1=~{fastq_1} \
    F2=~{fastq_2} \
    O=~{output_bam_basename} \
    SM=~{library_name} \
    RG=~{readgroup_name} \
    LB=~{library_name} \
    PU=~{output_bam_basename} \
    PL=~{platform_name} \
    DT=~{run_date} \
    CN=~{sequencing_center}
  >>>
  
  runtime {
    docker: gotc_docker
    memory: machine_mem_gb + " GB"
    disk: disk_space_gb + " GB"
    preemptible: true
  }
  
  output {
    File output_unmapped_bam = "~{output_bam_basename}"
  }
}