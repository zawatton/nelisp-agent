;; Two facts, near and far apart.  The per-path reference cap was defaulted to
;; 2 from a question whose facts sat on adjacent lines, where one line range
;; covered both; docs/bulk-policy.md records that facts far apart in a large
;; file were not measured.  These two cases differ only in that distance: same
;; size (5,536 B), same line count, same two facts, same question.
(:version 1
 :cases
 ((:id "spread-adjacent"
   :question "受電設備の保守担当部署と、年次点検の停電時間を答えてください。"
   :paths ("spread/log-adjacent.txt") :required ("第二技術課" "2時間") :absent nil)
  (:id "spread-distant"
   :question "受電設備の保守担当部署と、年次点検の停電時間を答えてください。"
   :paths ("spread/log-distant.txt") :required ("第二技術課" "2時間") :absent nil)))
