(:version 1
 :cases
 ((:id "en-readings"
   :question "What is the insulation resistance of circuit 2?"
   :paths ("en/readings.txt")
   :required ("Circuit 2 insulation resistance is 85 MOhm") :absent nil)
  (:id "en-equipment"
   :question "What is the rated breaking current of Building B extension?"
   :paths ("en/equipment.txt")
   :required ("Building B extension rated breaking current is 20 kA") :absent nil)
  (:id "en-procedure-conflict"
   :question "What is the inspection interval for the high-voltage panel?"
   :paths ("en/procedure-a.txt" "en/procedure-b.txt")
   :required ("The inspection interval is 6 months") :absent nil)
  (:id "en-datasheet-footnote"
   :question "What is the contract demand?"
   :paths ("en/datasheet.txt")
   :required ("Contract demand is 250 kW") :absent nil)
  (:id "en-invoice"
   :question "What is the total amount?"
   :paths ("en/invoice.txt")
   :required ("The total is 62700") :absent nil)))
