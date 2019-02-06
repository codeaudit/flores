# Copyright (c) Facebook, Inc. and its affiliates.
# All rights reserved.
#
# This source code is licensed under the license found in the
# LICENSE file in the root directory of this source tree.
#
#!/bin/bash

SRC=si
TGT=en

BPESIZE=5000
TRAIN_MINLEN=6  # remove sentences with <6 BPE tokens
TRAIN_MAXLEN=250  # remove sentences with >250 BPE tokens

ROOT=$(dirname "$0")
SCRIPTS=$ROOT/scripts
DATA=$ROOT/data
TMP=$DATA/wiki_${SRC}_${TGT}_bpe${BPESIZE}
DATABIN=$ROOT/data-bin/wiki_${SRC}_${TGT}_bpe${BPESIZE}
mkdir -p $TMP $DATABIN

SRC_TOKENIZER="bash $SCRIPTS/indic_norm_tok.sh $SRC"
TGT_TOKENIZER="cat"  # learn target-side BPE over untokenized (raw) text
SPM_TRAIN=$SCRIPTS/spm_train.py
SPM_ENCODE=$SCRIPTS/spm_encode.py

URLS=(
    "http://data.statmt.org/wmt19/parallel-corpus-filtering/all-clean.tgz"
    "https://github.com/facebookresearch/flores/raw/master/data/wikipedia_en_ne_si_test_sets.tgz"
)
ARCHIVES=(
    "all-clean.tgz"
    "wikipedia_en_ne_si_test_sets.tgz"
)
TRAIN_SETS=(
    "all-clean-si/GNOMEKDEUbuntu.en-si"
    "all-clean-si/OpenSubtitles2018.en-si"
)
VALID_SET="wikipedia_en_ne_si_test_sets/wikipedia.dev.si-en"
TEST_SET="wikipedia_en_ne_si_test_sets/wikipedia.devtest.si-en"

FAIRSEQ=fairseq
if [ ! -e $FAIRSEQ ]; then
    echo "Cloning fairseq repository..."
    git clone https://github.com/pytorch/fairseq.git
fi

# download and extract data
for ((i=0;i<${#URLS[@]};++i)); do
    ARCHIVE=$DATA/${ARCHIVES[i]}
    if [ -f $ARCHIVE ]; then
        echo "$ARCHIVE already exists, skipping download"
    else
        URL=${URLS[i]}
        wget -P $DATA "$URL"
        if [ -f $ARCHIVE ]; then
            echo "$URL successfully downloaded."
        else
            echo "$URL not successfully downloaded."
            exit -1
        fi
    fi
    FILE=${ARCHIVE:0:-4}
    if [ -e $FILE ]; then
        echo "$FILE already exists, skipping extraction"
    else
        tar -C $DATA -xzvf $ARCHIVE
    fi
done

echo "pre-processing train data..."
for FILE in "${TRAIN_SETS[@]}" ; do
    $SRC_TOKENIZER $DATA/$FILE.$SRC
done > $TMP/train.$SRC
for FILE in "${TRAIN_SETS[@]}"; do
    $TGT_TOKENIZER $DATA/$FILE.$TGT
done > $TMP/train.$TGT

echo "pre-processing dev/test data..."
$SRC_TOKENIZER $DATA/${VALID_SET}.$SRC > $TMP/valid.$SRC
$TGT_TOKENIZER $DATA/${VALID_SET}.$TGT > $TMP/valid.$TGT
$SRC_TOKENIZER $DATA/${TEST_SET}.$SRC > $TMP/test.$SRC
$TGT_TOKENIZER $DATA/${TEST_SET}.$TGT > $TMP/test.$TGT

# learn BPE with sentencepiece
python $SPM_TRAIN \
  --input=$TMP/train.$SRC,$TMP/train.$TGT \
  --model_prefix=$DATABIN/sentencepiece.bpe \
  --vocab_size=$BPESIZE \
  --character_coverage=1.0 \
  --model_type=bpe

# encode train/valid/test
python $SPM_ENCODE \
  --model $DATABIN/sentencepiece.bpe.model \
  --output_format=piece \
  --inputs $TMP/train.$SRC $TMP/train.$TGT \
  --outputs $TMP/train.bpe.$SRC $TMP/train.bpe.$TGT \
  --min-len $TRAIN_MINLEN --max-len $TRAIN_MAXLEN
for SPLIT in "valid" "test"; do \
  python $SPM_ENCODE \
    --model $DATABIN/sentencepiece.bpe.model \
    --output_format=piece \
    --inputs $TMP/$SPLIT.$SRC $TMP/$SPLIT.$TGT \
    --outputs $TMP/$SPLIT.bpe.$SRC $TMP/$SPLIT.bpe.$TGT
done

# binarize data
python $FAIRSEQ/preprocess.py \
  --source-lang $SRC --target-lang $TGT \
  --trainpref $TMP/train.bpe --validpref $TMP/valid.bpe --testpref $TMP/test.bpe \
  --destdir $DATABIN \
  --joined-dictionary \
  --workers 4