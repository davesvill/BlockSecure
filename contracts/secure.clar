;; BlockSecure: Secure Crypto-Backed Lending Platform
;; A decentralized lending platform allowing users to take loans using cryptocurrency as collateral

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-INSUFFICIENT-FUNDS (err u100))
(define-constant ERR-UNAUTHORIZED (err u101))
(define-constant ERR-LOAN-NOT-FOUND (err u102))
(define-constant ERR-LOAN-ALREADY-EXISTS (err u103))
(define-constant ERR-LOAN-REPAYMENT-FAILED (err u104))
(define-constant ERR-LIQUIDATION-NOT-ALLOWED (err u105))
(define-constant ERR-INVALID-PARAMETER (err u106))
(define-constant ERR-INSUFFICIENT-COLLATERAL (err u107))

;; Maximum values to prevent overflow
(define-constant MAX-INTEREST-RATE u10000) ;; 100.00%
(define-constant MAX-LOAN-TERM u52560) ;; Approximately 1 year in blocks
(define-constant MAX-UINT u340282366920938463463374607431768211455)
(define-constant SECURITY-RATIO u150) ;; 150% minimum collateralization ratio

;; Data Maps
(define-map active-loans 
  {
    loan-id: uint,
    borrower: principal
  }
  {
    security-amount: uint,
    borrowed-amount: uint,
    interest-rate: uint,
    term-start-block: uint,
    term-duration: uint,
    is-active: bool
  }
)

(define-map payment-history
  {
    loan-id: uint,
    borrower: principal
  }
  {
    total-repaid: uint
  }
)

;; Variables
(define-data-var next-loan-id uint u0)

;; Internal Functions
(define-private (validate-loan-parameters 
    (security-amount uint)
    (borrowed-amount uint)
    (interest-rate uint)
    (term-duration uint)
  )
  (and
    (> security-amount u0)
    (<= security-amount MAX-UINT)
    (> borrowed-amount u0)
    (<= borrowed-amount MAX-UINT)
    (<= interest-rate MAX-INTEREST-RATE)
    (> term-duration u0)
    (<= term-duration MAX-LOAN-TERM)
  )
)

;; Validate loan ID exists and belongs to the borrower
(define-private (validate-loan-ownership (loan-id uint))
  (is-some 
    (map-get? active-loans {
      loan-id: loan-id, 
      borrower: tx-sender
    })
  )
)

;; Calculate minimum required security for a loan
(define-private (calculate-min-security (borrowed-amount uint))
  (/ (* borrowed-amount SECURITY-RATIO) u100)
)

;; Read-only Functions
(define-read-only (get-loan-details (loan-id uint) (borrower principal))
  (map-get? active-loans {loan-id: loan-id, borrower: borrower})
)

(define-read-only (get-payment-status (loan-id uint) (borrower principal))
  (map-get? payment-history {loan-id: loan-id, borrower: borrower})
)

;; Public Functions
(define-public (create-loan 
    (security-amount uint)
    (borrowed-amount uint)
    (interest-rate uint)
    (term-duration uint)
  )
  (let 
    (
      (current-loan-id (var-get next-loan-id))
      (new-loan-id (+ current-loan-id u1))
    )
    ;; Validate loan parameters
    (asserts! 
      (validate-loan-parameters 
        security-amount 
        borrowed-amount 
        interest-rate 
        term-duration
      ) 
      ERR-INVALID-PARAMETER
    )
    
    ;; Check if loan already exists
    (asserts! 
      (is-none 
        (map-get? active-loans {loan-id: new-loan-id, borrower: tx-sender})
      ) 
      ERR-LOAN-ALREADY-EXISTS
    )
    
    ;; Validate security amount
    (asserts! 
      (>= security-amount (calculate-min-security borrowed-amount)) 
      ERR-INSUFFICIENT-COLLATERAL
    )
    
    ;; Create loan entry
    (map-set active-loans 
      {loan-id: new-loan-id, borrower: tx-sender}
      {
        security-amount: security-amount,
        borrowed-amount: borrowed-amount,
        interest-rate: interest-rate,
        term-start-block: block-height,
        term-duration: term-duration,
        is-active: true
      }
    )
    
    ;; Update next loan ID
    (var-set next-loan-id new-loan-id)
    
    ;; Return loan ID
    (ok new-loan-id)
  )
)

(define-public (add-security (loan-id uint) (additional-amount uint))
  (let
    (
      ;; Validate loan ownership first
      (loan-exists (asserts! 
        (validate-loan-ownership loan-id) 
        ERR-UNAUTHORIZED
      ))
      
      (loan (unwrap! 
        (map-get? active-loans {loan-id: loan-id, borrower: tx-sender}) 
        ERR-LOAN-NOT-FOUND
      ))
    )
    ;; Validate loan is active
    (asserts! (get is-active loan) ERR-UNAUTHORIZED)
    
    ;; Validate additional security amount
    (asserts! (> additional-amount u0) ERR-INVALID-PARAMETER)
    
    ;; Check that new total security won't overflow
    (let
      (
        (new-security-amount (+ (get security-amount loan) additional-amount))
      )
      (asserts! (<= new-security-amount MAX-UINT) ERR-INVALID-PARAMETER)
      
      ;; Update loan with new security amount
      (map-set active-loans 
        {loan-id: loan-id, borrower: tx-sender}
        (merge loan {security-amount: new-security-amount})
      )
      
      (ok new-security-amount)
    )
  )
)

(define-public (withdraw-security (loan-id uint) (withdraw-amount uint))
  (let
    (
      ;; Validate loan ownership first
      (loan-exists (asserts! 
        (validate-loan-ownership loan-id) 
        ERR-UNAUTHORIZED
      ))
      
      (loan (unwrap! 
        (map-get? active-loans {loan-id: loan-id, borrower: tx-sender}) 
        ERR-LOAN-NOT-FOUND
      ))
    )
    ;; Validate loan exists and is active
    (asserts! (get is-active loan) ERR-UNAUTHORIZED)
    
    ;; Validate withdrawal amount
    (asserts! (> withdraw-amount u0) ERR-INVALID-PARAMETER)
    (asserts! (<= withdraw-amount (get security-amount loan)) ERR-INSUFFICIENT-FUNDS)
    
    ;; Calculate new security amount after withdrawal
    (let
      (
        (new-security-amount (- (get security-amount loan) withdraw-amount))
        (min-required-security (calculate-min-security (get borrowed-amount loan)))
      )
      ;; Ensure remaining security meets minimum requirement
      (asserts! (>= new-security-amount min-required-security) ERR-INSUFFICIENT-COLLATERAL)
      
      ;; Update loan with new security amount
      (map-set active-loans 
        {loan-id: loan-id, borrower: tx-sender}
        (merge loan {security-amount: new-security-amount})
      )
      
      (ok withdraw-amount)
    )
  )
)

(define-public (repay-loan (loan-id uint))
  (let 
    (
      ;; Validate loan ownership first
      (loan-exists (asserts! 
        (validate-loan-ownership loan-id) 
        ERR-UNAUTHORIZED
      ))
      
      (loan (unwrap! 
        (map-get? active-loans {loan-id: loan-id, borrower: tx-sender}) 
        ERR-LOAN-NOT-FOUND
      ))
      (current-payments (default-to 
        {total-repaid: u0} 
        (map-get? payment-history {loan-id: loan-id, borrower: tx-sender})
      ))
    )
    ;; Validate loan exists and is active
    (asserts! (get is-active loan) ERR-UNAUTHORIZED)
    
    ;; Calculate total repayment amount with interest
    (let 
      (
        (total-repayment (+ 
          (get borrowed-amount loan)
          (/ (* (get borrowed-amount loan) (get interest-rate loan)) u100)
        ))
      )
      ;; Validate repayment amount doesn't overflow
      (asserts! (<= total-repayment MAX-UINT) ERR-LOAN-REPAYMENT-FAILED)
      
      ;; Update loan status
      (map-set active-loans 
        {loan-id: loan-id, borrower: tx-sender}
        (merge loan {is-active: false})
      )
      
      ;; Track repayments
      (map-set payment-history
        {loan-id: loan-id, borrower: tx-sender}
        {total-repaid: total-repayment}
      )
      
      (ok total-repayment)
    )
  )
)

(define-public (liquidate-loan (loan-id uint))
  (let 
    (
      ;; Validate loan ownership first
      (loan-exists (asserts! 
        (validate-loan-ownership loan-id) 
        ERR-UNAUTHORIZED
      ))
      
      (loan (unwrap! 
        (map-get? active-loans {loan-id: loan-id, borrower: tx-sender}) 
        ERR-LOAN-NOT-FOUND
      ))
    )
    ;; Validate loan exists
    (asserts! (get is-active loan) ERR-UNAUTHORIZED)
    
    ;; Check if loan is past due
    (asserts! 
      (> (- block-height (get term-start-block loan)) 
         (get term-duration loan)) 
      ERR-LIQUIDATION-NOT-ALLOWED
    )
    
    ;; Mark loan as inactive and allow liquidation
    (map-set active-loans 
      {loan-id: loan-id, borrower: tx-sender}
      (merge loan {is-active: false})
    )
    
    (ok true)
  )
)