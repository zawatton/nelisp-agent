(:version 1
 :cases
 ((:id "field-person-conflict"
   :question "設備の保安担当者は誰ですか。"
   :paths ("nonnum/person-a.txt" "nonnum/person-b.txt")
   :required ("設備の保安担当者は佐藤です") :absent nil)
  (:id "field-negation-conflict"
   :question "夜間作業は許可されていますか。"
   :paths ("nonnum/night-a.txt" "nonnum/night-b.txt")
   :required ("夜間作業は許可されています") :absent nil)
  (:id "field-consistent"
   :question "設置場所はどこですか。"
   :paths ("nonnum/consistent-a.txt" "nonnum/consistent-b.txt")
   :required ("設置場所はA棟です") :absent nil)
  (:id "field-parallel-subjects"
   :question "第2回路の測定者は誰ですか。"
   :paths ("nonnum/circuits.txt")
   :required ("第2回路の測定者は田中です") :absent nil)
  (:id "field-multi-entry"
   :question "立会者を一名挙げてください。"
   :paths ("nonnum/roster.txt")
   :required ("立会者は佐藤です") :absent nil)))
