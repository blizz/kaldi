#!/bin/bash -e

# Copyright 2014 QCRI (author: Ahmed Ali)
#           2019 Dongji Gao
# Apache 2.0

# This is an example script for subword implementation

num_jobs=120
num_decode_jobs=40
decode_gmm=true
stage=0
overwrite=false
num_merges=1000

dir1=/export/corpora/LDC/LDC2013S02/
dir2=/export/corpora/LDC/LDC2013S07/
dir3=/export/corpora/LDC/LDC2014S07/
text1=/export/corpora/LDC/LDC2013T17/
text2=/export/corpora/LDC/LDC2013T04/
text3=/export/corpora/LDC/LDC2014T17/

galeData=GALE
. ./cmd.sh ## You'll want to change cmd.sh to something that will work on your system.
           ## This relates to the queue.
. ./path.sh
. ./utils/parse_options.sh  # e.g. this parses the above options
                            # if supplied.

if [ $stage -le 0 ]; then

  if [ -f data/train/text ] && ! $overwrite; then
    echo "$0: Not processing, probably script have run from wrong stage"
    echo "Exiting with status 1 to avoid data corruption"
    exit 1;
  fi

  echo "$0: preparing data..."
  local/prepare_data.sh --dir1 $dir1 --dir2 $dir2 --dir3 $dir3 \
                        --text1 $text1 --text2 $text2 --text3 $text3

  echo "$0: Preparing lexicon and LM..." 
  local/prepare_dict_subword.sh --num_merges $num_merges

  utils/subword/prepare_lang_subword.sh data/local/dict "<UNK>" data/local/lang data/lang

  for set in train test; do
    utils/subword/prepare_subword_text.sh data/$set/text data/local/pair_code.txt data/$set/text
  done

  local/prepare_lm_subword.sh

  utils/format_lm.sh data/lang data/local/lm/lm.gz \
                     data/local/dict/lexicon.txt data/lang_test
fi

mfccdir=mfcc
if [ $stage -le 1 ]; then
  echo "$0: Preparing the test and train feature files..."
  for x in train test ; do
    steps/make_mfcc.sh --cmd "$train_cmd" --nj $num_jobs \
      data/$x exp/make_mfcc/$x $mfccdir
    utils/fix_data_dir.sh data/$x # some files fail to get mfcc for many reasons
    steps/compute_cmvn_stats.sh data/$x exp/make_mfcc/$x $mfccdir
  done
fi

if [ $stage -le 2 ]; then
  echo "$0: creating sub-set and training monophone system"
  utils/subset_data_dir.sh data/train 10000 data/train.10K || exit 1;

  steps/train_mono.sh --nj 40 --cmd "$train_cmd" \
    data/train.10K data/lang exp/mono_subword || exit 1;
fi

if [ $stage -le 3 ]; then
  echo "$0: Aligning data using monophone system"
  steps/align_si.sh --nj $num_jobs --cmd "$train_cmd" \
    data/train data/lang exp/mono_subword exp/mono_ali_subword || exit 1;

  echo "$0: training triphone system with delta features"
  steps/train_deltas.sh --cmd "$train_cmd" \
    2500 30000 data/train data/lang exp/mono_ali_subword exp/tri1_subword || exit 1;
fi

if [ $stage -le 4 ] && $decode_gmm; then
  utils/mkgraph.sh data/lang_test exp/tri1_subword exp/tri1_subword/graph
  steps/decode.sh  --nj $num_decode_jobs --cmd "$decode_cmd" \
    exp/tri1_subword/graph data/test exp/tri1_subword/decode
fi

if [ $stage -le 5 ]; then
  echo "$0: Aligning data and retraining and realigning with lda_mllt"
  steps/align_si.sh --nj $num_jobs --cmd "$train_cmd" \
    data/train data/lang exp/tri1_subword exp/tri1_ali_subword || exit 1;

  steps/train_lda_mllt.sh --cmd "$train_cmd" 4000 50000 \
    data/train data/lang exp/tri1_ali_subword exp/tri2b_subword || exit 1;
fi

if [ $stage -le 6 ] && $decode_gmm; then
  utils/mkgraph.sh data/lang_test exp/tri2b_subword exp/tri2b_subword/graph
  steps/decode.sh --nj $num_decode_jobs --cmd "$decode_cmd" \
    exp/tri2b_subword/graph data/test exp/tri2b_subword/decode
fi

if [ $stage -le 7 ]; then
  echo "$0: Aligning data and retraining and realigning with sat_basis"
  steps/align_si.sh --nj $num_jobs --cmd "$train_cmd" \
    data/train data/lang exp/tri2b_subword exp/tri2b_ali_subword || exit 1;

  steps/train_sat_basis.sh --cmd "$train_cmd" \
    5000 100000 data/train data/lang exp/tri2b_ali_subword exp/tri3b_subword || exit 1;

  steps/align_fmllr.sh --nj $num_jobs --cmd "$train_cmd" \
    data/train data/lang exp/tri3b_subword exp/tri3b_ali_subword || exit 1;
fi

if [ $stage -le 8 ] && $decode_gmm; then
  utils/mkgraph.sh data/lang_test exp/tri3b_subword exp/tri3b_subword/graph
  steps/decode_fmllr.sh --nj $num_decode_jobs --cmd \
    "$decode_cmd" exp/tri3b_subword/graph data/test exp/tri3b_subword/decode
fi

if [ $stage -le 9 ]; then
  echo "$0: Training a regular chain model using the e2e alignments..."
  local/chain/run_tdnn.sh --gmm tri3b_subword
fi

echo "$0: training succeed"
exit 0
