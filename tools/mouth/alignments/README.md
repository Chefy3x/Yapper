# MFA alignments for the extra training corpora

Montreal Forced Aligner 3.4.3 with the english_us_arpa acoustic model and dictionary (v3.0.0), default beams.
Each archive unpacks to a folder of `<speaker>/<stem>.TextGrid` (words and phones tiers), MFA's
`alignment_analysis.csv`, and `rejected.txt`: the utterances `vibecode.py check-align --write` threw out
(aligned speech under 6 dB above the aligned silence, most phones at MFA's 30 ms minimum, many unknown words
or under 0.1 s of speech). Unpack under `$YAPPER_MOUTH_DATA/align/` (as `sc/` and `ps/`), put the audio where
`CORPORA` in `vibecode.py` expects it, then `vibecode.py prep speech-commands peoples-speech`.

- `speech-commands.tar.gz`: Speech Commands v0.02 (CC BY 4.0, Pete Warden / Google). At most 12 clips per
  speaker (28,792 clips, 2,618 speakers); speaker folders are the corpus's speaker hashes, stems
  `<word>_<speaker>_<n>`. 2,091 rejected. Held out: the speakers in the corpus's `testing_list.txt`.
- `peoples-speech.tar.gz`: The People's Speech, "clean" subset (CC-BY, MLCommons), train shards 00000, 00300
  and 00600 of 804 (5,602 segments, 22 h). Folders are the source recordings (archive.org item, sanitised);
  the TextGrids carry the corpus's transcripts. 7 rejected. Held out: one recording in ten, by MD5 of its name.
