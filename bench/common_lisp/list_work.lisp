;; SPDX-License-Identifier: MPL-2.0
;;

(defun range (n acc)
	(if (= n 0)
		acc
		(range (- n 1) (cons n acc))))

(let ((xs (range 1000 '())))
	(write (length (reverse xs)))
	(terpri))