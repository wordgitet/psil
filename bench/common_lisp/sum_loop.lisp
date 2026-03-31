(defun sum-to (n acc)
	(if (= n 0)
		acc
		(sum-to (- n 1) (+ acc n))))

(write (sum-to 1000 0))
(terpri)
;; SPDX-License-Identifier: MPL-2.0
;;
