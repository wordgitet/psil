(defun fib (n)
	(if (< n 2)
		n
		(+ (fib (- n 1)) (fib (- n 2)))))

(write (fib 26))
(terpri)
;; SPDX-License-Identifier: MPL-2.0
;;
