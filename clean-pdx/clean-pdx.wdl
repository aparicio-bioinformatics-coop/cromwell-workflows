version 1.0 

# Copyright Aparicio Lab, 2022
# This WDL pipeline takes a BAM file of a PDX sample and strips out mouse (host) reads from the desired human reads.

# WORKFLOW DEFINITION
workflow CleanPDX {
	input {
		File input_bam
		String sample_ID

    # Combo mouse/human references:
    File mouse_human_genome_fasta
    File mouse_human_genome_fasta_index
    File mouse_human_genome_dict 

		Int num_threads = 20

    String bwa_commandline = "bwa mem -K 100000000 -p -v 3 -t 16 -Y $bash_ref_fasta"

		String gotc_docker = "us.gcr.io/broad-gotc-prod/genomes-in-the-cloud:2.4.3-1564508330"
    String gotc_path = "/usr/gitc/"
		Int compression_level = 5
		Int preemptible_tries = 2
	}


	# Get the BWA version to use for alignment
	call GetBwaVersion


	# Convert input_bam to paired fastq reads
	call SamToFastqAndBwaMem {
    input:
      input_bam = input_bam,
      bwa_commandline = bwa_commandline,
      output_bam_basename = sample_ID + ".aligned.unsorted",
      mouse_human_genome_fasta = mouse_human_genome_fasta,
      mouse_human_genome_fasta_index = mouse_human_genome_fasta_index,
      mouse_human_genome_dict = mouse_human_genome_dict,
      bwa_version = GetBwaVersion.bwa_version,
      compression_level = compression_level,
      preemptible_tries = 1,
      gotc_docker = gotc_docker
  }


  # Sort the output of SamToFastqAndBwaMem so that it can be filtered
  call SortBwaBam {
  	input:
  		input_bam = SamToFastqAndBwaMem.output_bam,
  		output_bam_basename = sample_ID + ".aligned.sorted",
  		compression_level = compression_level,
  		preemptible_tries = preemptible_tries,
  		gotc_docker = gotc_docker
  }


  # Filter out mouse alignments from the sorted BAM file
  call FilterReads {
  	input:
  		input_bam = SortBwaBam.output_bam,
  		output_bam_basename = sample_ID + ".sorted.filtered",
  		preemptible_tries = preemptible_tries,
  		gotc_docker = gotc_docker
  }


  # Extract non-mouse reads by converting to FASTQ
  call ExtractHgReads {
    input:
      input_bam = FilterReads.output_bam,
      output_fastq_basename = sample_ID + ".sorted.hgonly",
      output_fastq_basename2 = sample_ID + ".2.sorted.hgonly",
      preemptible_tries = preemptible_tries,
      gotc_docker = gotc_docker
  }


  scatter (output_fastq in ExtractHgReads.output_fastqs) 
  {
    String output_basename = basename(output_fastq)

    # Convert final FASTQ to uBAM
    call FastqToSam {
      input:
        input_fastq = output_fastq,
        unsorted_bam_basename = output_basename + ".unsorted.unmapped.bam",
        sample_ID = sample_ID,
        compression_level = compression_level,
        preemptible_tries = preemptible_tries,
        gotc_docker = gotc_docker
    }

    # Sort the uBAM
    call SortSam {
      input:
        input_bam = FastqToSam.output_bam,
        sorted_bam_basename = output_basename + ".unmapped",
        compression_level = compression_level,
        preemptible_tries = preemptible_tries,
        gotc_docker = gotc_docker
    }
  }

  output {
    Array[File] output_bams = SortSam.sorted_bam
  }
}


# TASK DEFINITIONS
	
# Get the BWA version to use for alignment
task GetBwaVersion {
  command {
    # not setting set -o pipefail here because /bwa has a rc=1 and we dont want to allow rc=1 to succeed because
    # the sed may also fail with that error and that is something we actually want to fail on.
    /usr/gitc/bwa 2>&1 | \
    grep -e '^Version' | \
    sed 's/Version: //'
  }
  
  runtime {
    docker: "us.gcr.io/broad-gotc-prod/genomes-in-the-cloud:2.5.7-2021-06-09_16-47-48Z"
    memory: "1 GB"
  }

  output {
    String bwa_version = read_string(stdout())
  }
}


# Convert input_bam to paired fastq reads and aligns to a combined mouse/human reference
task SamToFastqAndBwaMem {
	input {
    	File input_bam
    	String bwa_commandline
    	String bwa_version
    	String output_bam_basename
    	
      File mouse_human_genome_fasta
      File mouse_human_genome_fasta_index
      File mouse_human_genome_dict

      File mouse_human_genome_sa
      File mouse_human_genome_amb
      File mouse_human_genome_ann
      File mouse_human_genome_bwt
      File mouse_human_genome_pac
      File? mouse_human_genome_alt

    	Int compression_level
    	Int preemptible_tries

    	String gotc_docker
	}

  Float unmapped_bam_size = size(input_bam, "GB")

  # Since ref_size/bwa_ref_size don't like getting the size of the input ref files, just estimate that total is ~15GB and add to disk_size

  # Sometimes the output is larger than the input, or a task can spill to disk.
  # In these cases we need to account for the input (1) and the output (1.5) or the input(1), the output(1), and spillage (.5).
  Float disk_multiplier = 2.5
  Int disk_size = ceil(unmapped_bam_size + 16 + (disk_multiplier * unmapped_bam_size) + 200)

	command <<<
  set -o pipefail
  set -e
  # set the bash variable needed for the command-line
  bash_ref_fasta=~{mouse_human_genome_fasta}
  java -Xms3000m -jar /usr/gitc/picard.jar \
  SamToFastq \
  INPUT=~{input_bam} \
  FASTQ=/dev/stdout \
  INTERLEAVE=true \
  VALIDATION_STRINGENCY=LENIENT \
  NON_PF=true | \
  /usr/gitc/~{bwa_commandline} /dev/stdin - 2> >(tee ~{output_bam_basename}.bwa.stderr.log >&2) | \
  samtools view -1 - > ~{output_bam_basename}.bam
	>>>

	runtime {
		docker: gotc_docker
		preemptible: true
		maxRetries: preemptible_tries
		memory: "24 GB"
		cpu: 18
		disk: disk_size + " GB"
	}

	output {
    	File output_bam = "~{output_bam_basename}.bam"
    	File bwa_stderr_log = "~{output_bam_basename}.bwa.stderr.log"
   	}
}


# Sort the BAM file outputted by BWA mem
task SortBwaBam {
  input {
    File input_bam
    String output_bam_basename
    
    Int preemptible_tries
    Int compression_level

    String gotc_docker
  }

  # SortBwaBam spills to disk a lot more because we are only store 300000 records in RAM now because its faster for our data so it needs
  # more disk space.  Also it spills to disk in an uncompressed format so we need to account for that with a larger multiplier
  
  Float sort_sam_disk_multiplier = 3.25
  Int disk_size = ceil(sort_sam_disk_multiplier * size(input_bam, "GB")) + 20

  command <<<
    java -Dsamjdk.compression_level=~{compression_level} -Xms4000m -jar /usr/gitc/picard.jar \
      SortSam \
      INPUT=~{input_bam} \
      OUTPUT=~{output_bam_basename}.bam \
      SORT_ORDER="coordinate" \
      CREATE_INDEX=true \
      CREATE_MD5_FILE=true \
      MAX_RECORDS_IN_RAM=300000
  >>>

  runtime {
    docker: gotc_docker
    disk: disk_size + " GB"
    cpu: "1"
    memory: "5000 MB"
    preemptible: true
    maxRetries: preemptible_tries
  }

  output {
    File output_bam = "~{output_bam_basename}.bam"
    File output_bam_index = "~{output_bam_basename}.bai"
    File output_bam_md5 = "~{output_bam_basename}.bam.md5"
  }
}


# Filter out mouse alignments from the sorted BAM file
task FilterReads {
	input {
		File input_bam
		String output_bam_basename
		
		Int preemptible_tries
		
		String gotc_docker
	}

	Float input_bam_size = size(input_bam, "GB")
	Int disk_size = ceil(input_bam_size * 2)

	command <<<
  set -o pipefail
  set -e
  samtools view -h ~{input_bam} |
  awk '{if($3 !~ /m_chr/){print $0}}' |
  samtools view -Shb - > ~{output_bam_basename}.bam
	>>>

	runtime {
		docker: gotc_docker
		memory: "14 GB"
		cpu: 16
		disk: disk_size + " GB"
		preemptible: true
		maxRetries: preemptible_tries
	}

	output {
    File output_bam = "~{output_bam_basename}.bam"
  }
}


# Extract non-mouse reads by converting to FASTQ
task ExtractHgReads {
  input {
    File input_bam
    String output_fastq_basename
    String output_fastq_basename2
    
    Int preemptible_tries
    
    String gotc_docker
  }

  Float input_bam_size = size(input_bam, "GB")
  Int disk_size = ceil(input_bam_size * 3.5)

  command <<<
  set -o pipefail
  set -e
  java -Xms4000m -jar /usr/gitc/picard.jar \
  SortSam \
  INPUT=~{input_bam} \
  OUTPUT=/dev/stdout \
  SORT_ORDER="queryname" \ |
  samtools fastq -1 ~{output_fastq_basename}.fastq.gz -2 ~{output_fastq_basename2}.fastq.gz -0 /dev/null -s /dev/null -n /dev/stdin
  >>>

  runtime {
    docker: gotc_docker
    memory: "14 GB"
    cpu: 16
    disk: disk_size + " GB"
    preemptible: true
    maxRetries: preemptible_tries
  }

  output {
    Array[File] output_fastqs = glob("*.fastq.gz")
  }
}


task FastqToSam {
  input {
    File input_fastq
    String unsorted_bam_basename
    String sample_ID

		Int preemptible_tries
    Int compression_level
		
		String gotc_docker
  }

  Float sort_sam_disk_multiplier = 3.25
  Int disk_size = ceil(sort_sam_disk_multiplier * size(input_fastq, "GB")) + 20

  command <<<
    java -Xms4000m -jar /usr/gitc/picard.jar \
    FastqToSam \
    F1=~{input_fastq} \
    O=~{unsorted_bam_basename} \
    SM=~{sample_ID} \
    SORT_ORDER=queryname
  >>>

  runtime {
    docker: gotc_docker
    memory: "14 GB"
    disk: disk_size + " GB"
    preemptible: true
    maxRetries: preemptible_tries
  }

  output {
    File output_bam = "~{unsorted_bam_basename}"
  }
}

task SortSam {
  input {
    File input_bam
    String sorted_bam_basename

    Int preemptible_tries
    Int compression_level
    
    String gotc_docker
  }

  Float input_bam_size = size(input_bam, "GB")
  Int disk_size = ceil(input_bam_size * 2)

  command <<<
    java -Xms4000m -jar /usr/gitc/picard.jar \
    SortSam \
    INPUT=~{input_bam} \
    OUTPUT=~{sorted_bam_basename}.bam \
    SORT_ORDER="queryname" \
    CREATE_INDEX=true \
    CREATE_MD5_FILE=true \
    MAX_RECORDS_IN_RAM=300000
  >>>

  runtime {
    docker: gotc_docker
    memory: "14 GB"
    disk: disk_size + " GB"
    preemptible: true
    maxRetries: preemptible_tries
  }

  output {
    File sorted_bam = "~{sorted_bam_basename}.bam"
  }
}
