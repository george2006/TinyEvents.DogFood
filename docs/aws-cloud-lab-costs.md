# AWS Laboratory Cost Envelope

Indicative estimate for **one** Linux On-Demand `m7i.2xlarge` instance in Ireland,
without discounts, credits, reservations, or Spot. Price checked on September 5,
2026: **0.4494 USD/hour**. AWS's published catalog reports an update timestamp
of `2026-09-04T23:11:17Z` and rate code
`G2JRWMZ4TH8WDF33.JRTCKXETXF.6YS6EN2CT7`.
[AWS pricing catalog, Ireland/Linux](https://b0.p.awsstatic.com/pricing/2.0/meteredUnitMaps/ec2/USD/current/ec2-ondemand-without-sec-sel/EU%20%28Ireland%29/Linux/index.json).

The public IPv4 address adds **0.005 USD/hour** while in use.
[Official IPv4 pricing](https://aws.amazon.com/vpc/pricing/).

| Total running time | VM only | VM + one IPv4 address |
| --- | ---: | ---: |
| 2 hours | 0.90 USD | 0.91 USD |
| 24 hours | 10.79 USD | 10.91 USD |
| 48 hours | 21.57 USD | 21.81 USD |
| 72 hours | 32.36 USD | 32.72 USD |

Add the 150 GiB gp3 disk, S3 storage/requests, and any billable data transfer.
For the first cycle, allow **an additional 5-10 USD**, not a verified tariff,
assuming the disk is deleted after 2-3 days, modest results (up to approximately
10 GB), no large dumps, and no additional services. Review this allowance before
deployment. [EBS pricing](https://aws.amazon.com/ebs/pricing/) and
[S3 pricing](https://aws.amazon.com/s3/pricing/).

A first cycle covering preparation, smoke, scaling, and a 24-hour soak could
require approximately **30-48 running hours**. Repetitions could extend that to
72 hours. **Reserve 50-60 EUR for that first cycle** as a planning allowance,
not an exact USD conversion, fixed quote, or spending authorization. Exchange
rates, applicable VAT, credits, and actual evidence volume affect the bill.
The previously discussed 200 EUR would provide headroom for repeated tests,
not the expected initial spend.

This does not change the TTL: the script allows up to 30 hours per deployment.
The 48-72 hours above are aggregate time across multiple runs, not an unlimited
VM left running for three days.

Stopping EC2 **does not delete its disk**, which remains billable while it
exists. Download results before removing resources. S3 has 30-day retention,
not free storage. The current timer depends on the host; it is not an AWS-enforced
spending cutoff.
[Charges that continue after stopping EC2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-lifecycle.html).
