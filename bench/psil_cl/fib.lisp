;; SPDX-License-Identifier: MPL-2.0
;;

(defun fib (n)
	(if (< n 2)
		n
		(+ (fib (- n 1)) (fib (- n 2)))))

(fib 26)
