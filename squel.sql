create table Concession (
  concession_id    int auto_increment primary key,
  type             varchar(50)    not null,
  discount_percent decimal(5,2)   not null
    check (discount_percent between 0 and 100)
);

create table Passenger (
  passenger_id  int auto_increment primary key,
  name          varchar(100)      not null,
  age           int               not null,
  gender        enum('M','F','O') not null,
  concession_id int,
  foreign key (concession_id)
    references Concession(concession_id)
);

create table station (
  station_id       int auto_increment primary key,
  code             varchar(10)     unique not null,
  name             varchar(100)    not null,
  how_long_to_wait time            not null,
  location         varchar(100)
);

create table Route (
  route_id               int auto_increment primary key,
  origin_station_id      int not null,
  destination_station_id int not null,
  foreign key (origin_station_id)
    references station(station_id),
  foreign key (destination_station_id)
    references station(station_id)
);

create table train (
  train_id  int auto_increment primary key,
  name      varchar(100) not null,
  route_id  int           not null,
  foreign key (route_id)
    references Route(route_id)
);

create table trainSchedule (
  train_id       int     not null,
  station_id     int     not null,
  stop_number    int     not null,
  arrival_time   time,
  departure_time time,
  primary key (train_id, stop_number),
  foreign key (train_id)   references train(train_id),
  foreign key (station_id) references station(station_id)
);

create table Class (
  class_id       int auto_increment primary key,
  name           varchar(50)   not null,
  fare_multiplier decimal(5,2) not null
);

create table trainClassAvailabilityA (
  train_id    int not null,
  class_id    int not null,
  total_seats int not null,
  primary key (train_id, class_id),
  foreign key (train_id) references train(train_id),
  foreign key (class_id) references Class(class_id)
);

create table trainClassAvailabilityB (
  train_id        int   not null,
  class_id        int   not null,
  travel_date     date  not null,
  available_seats int   not null,
  primary key (train_id, class_id, travel_date),
  foreign key (train_id) references train(train_id),
  foreign key (class_id) references Class(class_id)
);

create table ticket (
  ticket_id         int auto_increment primary key,
  passenger_id      int not null,
  train_id          int not null,
  class_id          int not null,
  travel_date       date    not null,
  booking_date      datetime not null default current_timestamp,
  status            enum('BOOKED','CANCELLED','RAC','WAITLIST') not null,
  seat_count        int     not null,
  base_fare         decimal(10,2) not null,
  concession_amount decimal(10,2) default 0,
  net_fare          decimal(10,2) as (base_fare - concession_amount) persistent,
  foreign key (passenger_id) references Passenger(passenger_id),
  foreign key (train_id)     references train(train_id),
  foreign key (class_id)     references Class(class_id)
);

create table Payment (
  payment_id   int auto_increment primary key,
  ticket_id    int not null,
  amount       decimal(10,2) not null,
  payment_mode enum('ONLINE','COUNTER') not null,
  payment_date datetime not null default current_timestamp,
  foreign key (ticket_id) references ticket(ticket_id)
);

create table Cancellation (
  cancellation_id int auto_increment primary key,
  ticket_id       int not null,
  cancel_date     datetime not null default current_timestamp,
  refund_amount   decimal(10,2) not null,
  processed       boolean not null default false,
  foreign key (ticket_id) references ticket(ticket_id)
);

delimiter $$

create trigger trg_ticket_after_insert
after insert on ticket
for each row
begin
  if new.status = 'BOOKED' then
    update trainClassAvailabilityB
      set available_seats = available_seats - new.seat_count
    where train_id    = new.train_id
      and class_id    = new.class_id
      and travel_date = new.travel_date;
  end if;
end$$

create trigger trg_ts_before_insupd
before insert on trainSchedule
for each row
begin
  declare w time;
  select how_long_to_wait into w
    from station
   where station_id = new.station_id;
  set new.departure_time =
      sec_to_time(time_to_sec(new.arrival_time) + time_to_sec(w));
end$$

create trigger trg_ts_before_update
before update on trainSchedule
for each row
begin
  declare w time;
  select how_long_to_wait into w
    from station
   where station_id = new.station_id;
  set new.departure_time =
      sec_to_time(time_to_sec(new.arrival_time) + time_to_sec(w));
end$$

delimiter ;


delimiter $$

drop procedure if exists sp_cancel_ticket$$

create procedure sp_cancel_ticket(in p_ticket_id int)
proc: begin
  declare v_tr    int;
  declare v_cl    int;
  declare v_dt    date;
  declare v_sc    int;
  declare v_rid   int;
  declare v_rsc   int;
  declare v_wid   int;

  select train_id, class_id, travel_date, seat_count
    into v_tr, v_cl, v_dt, v_sc
  from ticket
  where ticket_id = p_ticket_id
    and status    = 'BOOKED';

  if v_tr is null then
    leave proc;
  end if;

  update ticket
    set status = 'CANCELLED'
  where ticket_id = p_ticket_id;

  update trainClassAvailabilityB
    set available_seats = available_seats + v_sc
  where train_id    = v_tr
    and class_id    = v_cl
    and travel_date = v_dt;

  insert into Cancellation(ticket_id, refund_amount)
    select p_ticket_id,
           concession_amount + (base_fare - concession_amount)*0.5
      from ticket
     where ticket_id = p_ticket_id;

  select ticket_id, seat_count
    into v_rid, v_rsc
  from ticket
  where train_id    = v_tr
    and class_id    = v_cl
    and travel_date = v_dt
    and status      = 'RAC'
  order by booking_date
  limit 1;

  if v_rid is not null then
    update ticket
      set status = 'BOOKED'
    where ticket_id = v_rid;

    update trainClassAvailabilityB
      set available_seats = available_seats - v_rsc
    where train_id    = v_tr
      and class_id    = v_cl
      and travel_date = v_dt;

    select ticket_id
      into v_wid
    from ticket
    where train_id    = v_tr
      and class_id    = v_cl
      and travel_date = v_dt
      and status      = 'WAITLIST'
    order by booking_date
    limit 1;

    if v_wid is not null then
      update ticket
        set status = 'RAC'
      where ticket_id = v_wid;
    end if;
  end if;

end proc$$

delimiter ;
